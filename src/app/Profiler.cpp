#include "app/Profiler.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdarg>
#include <cstring>
#include <cstdio>
#include <ctime>
#include <deque>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>
#include <sstream>
#include <unordered_map>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

#include <dbghelp.h>
#else
#include <dlfcn.h>
#include <pthread.h>
#endif

namespace fs = std::filesystem;

namespace gitgud::prof
{
    namespace detail
    {
        std::atomic<bool> g_bCapturing{false};
    }

    namespace
    {
        using Clock = std::chrono::steady_clock;

        std::int64_t NowNs()
        {
            return std::chrono::duration_cast<std::chrono::nanoseconds>(
                Clock::now().time_since_epoch())
                .count();
        }

        // --- Names ---------------------------------------------------------
        struct Names
        {
            std::mutex m_Mutex;
            std::deque<std::string> m_Names{std::string("(root)")};
            std::deque<std::uintptr_t> m_Addresses{0}; // nonzero: named by symbol lookup
            std::deque<bool> m_Resolved{true};
            std::unordered_map<std::string, ZoneId> m_ByName;
            std::unordered_map<std::uintptr_t, ZoneId> m_ByAddress;
        };

        Names& TheNames()
        {
            static Names* s_pNames = new Names(); // never destroyed: threads may outlive statics
            return *s_pNames;
        }

        // --- Per thread ----------------------------------------------------
        struct Event
        {
            ZoneId m_Id;
            std::uint32_t m_uDepth;
            std::int64_t m_iBegin;
            std::int64_t m_iEnd;
        };

        struct Node
        {
            ZoneId m_Zone = kNoZone;
            std::int32_t m_iParent = -1;
            std::uint64_t m_uiCalls = 0;
            std::int64_t m_iInclusive = 0;
            std::int64_t m_iChildren = 0;
            std::int64_t m_iMax = 0;
        };

        struct Open
        {
            ZoneId m_Id;
            int m_iDepth;
            std::uint32_t m_uGen;
            std::int32_t m_iNode;
            std::int64_t m_iStart;
        };

        struct ThreadData
        {
            std::uint32_t m_uIndex = 0;
            std::uint64_t m_uiOsId = 0;
            std::string m_Name;
            Activity m_Activity;
            std::vector<Open> m_Open; // owner thread only

            std::mutex m_Mutex; // the capture data below
            std::uint32_t m_uGen = 0;
            std::vector<Event> m_Events;
            std::vector<Node> m_Tree;
            std::unordered_map<std::uint64_t, std::int32_t> m_Children;
        };

        struct Registry
        {
            std::mutex m_Mutex;
            std::vector<std::shared_ptr<ThreadData>> m_Threads;
        };

        Registry& TheRegistry()
        {
            static Registry* s_pRegistry = new Registry();
            return *s_pRegistry;
        }

        std::uint64_t OsThreadId()
        {
#if defined(_WIN32)
            return GetCurrentThreadId();
#else
            return static_cast<std::uint64_t>(reinterpret_cast<std::uintptr_t>(pthread_self()));
#endif
        }

        ThreadData& Td()
        {
            thread_local ThreadData* s_pTd = nullptr;
            if (!s_pTd)
            {
                auto td = std::make_shared<ThreadData>();
                td->m_uiOsId = OsThreadId();
                td->m_Open.reserve(64);
                Registry& reg = TheRegistry();
                std::lock_guard<std::mutex> lock(reg.m_Mutex);
                td->m_uIndex = static_cast<std::uint32_t>(reg.m_Threads.size() + 1);
                td->m_Name = "thread " + std::to_string(td->m_uIndex);
                reg.m_Threads.push_back(td);
                s_pTd = td.get();
            }
            return *s_pTd;
        }

        // --- Capture state ---------------------------------------------------
        std::atomic<std::uint32_t> g_uGen{0};
        std::atomic<std::int64_t> g_iCaptureStart{0};
        CaptureOptions g_Options;

        struct CounterSample
        {
            std::string m_Name;
            std::int64_t m_iTime;
            double m_fValue;
        };
        std::mutex g_CounterMutex;
        std::vector<CounterSample> g_Counters;

        // A finished capture, as the report reads it.
        struct ThreadCapture
        {
            std::uint32_t m_uIndex = 0;
            std::uint64_t m_uiOsId = 0;
            std::string m_Name;
            std::vector<Event> m_Events;
            std::vector<Node> m_Tree;
        };

        std::mutex g_LastMutex;
        std::vector<ZoneStats> g_LastStats;

        std::int32_t ChildNode(ThreadData& _Td, std::int32_t _iParent, ZoneId _Id)
        {
            const std::uint64_t key = (static_cast<std::uint64_t>(static_cast<std::uint32_t>(_iParent)) << 32) | _Id;
            const auto it = _Td.m_Children.find(key);
            if (it != _Td.m_Children.end())
            {
                return it->second;
            }
            const auto inode = static_cast<std::int32_t>(_Td.m_Tree.size());
            Node node;
            node.m_Zone = _Id;
            node.m_iParent = _iParent;
            _Td.m_Tree.push_back(node);
            _Td.m_Children.emplace(key, inode);
            return inode;
        }

        void BeginCaptured(ThreadData& _Td, ZoneId _Id, int _iDepth)
        {
            const std::uint32_t ugen = g_uGen.load(std::memory_order_acquire);
            std::int32_t iparent = 0;
            if (!_Td.m_Open.empty() && _Td.m_Open.back().m_uGen == ugen)
            {
                iparent = _Td.m_Open.back().m_iNode;
            }
            std::int32_t inode = 0;
            {
                std::lock_guard<std::mutex> lock(_Td.m_Mutex);
                if (!Capturing())
                {
                    return;
                }
                if (_Td.m_uGen != ugen)
                {
                    _Td.m_uGen = ugen;
                    _Td.m_Events.clear();
                    _Td.m_Tree.clear();
                    _Td.m_Children.clear();
                    _Td.m_Tree.push_back(Node{});
                    iparent = 0;
                }
                inode = ChildNode(_Td, iparent, _Id);
            }
            _Td.m_Open.push_back(Open{_Id, _iDepth, ugen, inode, NowNs()});
        }

        void EndCaptured(ThreadData& _Td, const Open& _Open)
        {
            const std::int64_t iend = NowNs();
            const std::int64_t idur = iend - _Open.m_iStart;
            std::lock_guard<std::mutex> lock(_Td.m_Mutex);
            if (!Capturing() || _Td.m_uGen != _Open.m_uGen ||
                _Open.m_iNode >= static_cast<std::int32_t>(_Td.m_Tree.size()))
            {
                return;
            }
            Node& node = _Td.m_Tree[static_cast<std::size_t>(_Open.m_iNode)];
            node.m_uiCalls++;
            node.m_iInclusive += idur;
            node.m_iMax = std::max(node.m_iMax, idur);
            if (node.m_iParent >= 0)
            {
                _Td.m_Tree[static_cast<std::size_t>(node.m_iParent)].m_iChildren += idur;
            }
            if (_Td.m_Events.size() < g_Options.m_uiMaxEvents || idur >= 1'000'000)
            {
                _Td.m_Events.push_back(
                    Event{_Open.m_Id, static_cast<std::uint32_t>(_Open.m_iDepth), _Open.m_iStart, iend});
            }
        }

        // --- Text helpers ------------------------------------------------------
        std::string JsonEscape(const std::string& _Text)
        {
            std::string out;
            out.reserve(_Text.size() + 8);
            for (const char c : _Text)
            {
                switch (c)
                {
                case '"':
                    out += "\\\"";
                    break;
                case '\\':
                    out += "\\\\";
                    break;
                case '\n':
                    out += "\\n";
                    break;
                case '\r':
                case '\t':
                    out += ' ';
                    break;
                default:
                    if (static_cast<unsigned char>(c) < 0x20)
                    {
                        out += ' ';
                    }
                    else
                    {
                        out += c;
                    }
                }
            }
            return out;
        }

        std::string XmlEscape(const std::string& _Text)
        {
            std::string out;
            out.reserve(_Text.size() + 8);
            for (const char c : _Text)
            {
                switch (c)
                {
                case '<':
                    out += "&lt;";
                    break;
                case '>':
                    out += "&gt;";
                    break;
                case '&':
                    out += "&amp;";
                    break;
                case '"':
                    out += "&quot;";
                    break;
                default:
                    out += static_cast<unsigned char>(c) < 0x20 ? ' ' : c;
                }
            }
            return out;
        }

        std::string Fmt(const char* _szFormat, ...)
        {
            char buf[1024];
            va_list args;
            va_start(args, _szFormat);
            std::vsnprintf(buf, sizeof(buf), _szFormat, args);
            va_end(args);
            return buf;
        }

        double Ms(std::int64_t _iNs)
        {
            return static_cast<double>(_iNs) / 1e6;
        }

        // --- Report ----------------------------------------------------------
        struct Edge
        {
            std::uint64_t m_uiCalls = 0;
            std::int64_t m_iTime = 0;
        };

        struct Analysis
        {
            std::unordered_map<ZoneId, ZoneStats> m_Stats;
            std::map<std::pair<ZoneId, ZoneId>, Edge> m_Edges; // caller, callee
        };

        std::vector<std::vector<std::int32_t>> ChildLists(const std::vector<Node>& _Tree)
        {
            std::vector<std::vector<std::int32_t>> kids(_Tree.size());
            for (std::size_t i = 1; i < _Tree.size(); ++i)
            {
                if (_Tree[i].m_iParent >= 0)
                {
                    kids[static_cast<std::size_t>(_Tree[i].m_iParent)].push_back(static_cast<std::int32_t>(i));
                }
            }
            return kids;
        }

        void Analyse(const ThreadCapture& _Thread, Analysis& _Out)
        {
            const auto& tree = _Thread.m_Tree;
            if (tree.empty())
            {
                return;
            }
            const auto kids = ChildLists(tree);
            // Depth-first, counting each zone's open instances so recursion
            // is counted once in inclusive time.
            std::unordered_map<ZoneId, int> onPath;
            struct Item
            {
                std::int32_t m_iNode;
                bool m_bLeave;
            };
            std::vector<Item> stack{{0, false}};
            while (!stack.empty())
            {
                const Item item = stack.back();
                stack.pop_back();
                const Node& node = tree[static_cast<std::size_t>(item.m_iNode)];
                if (item.m_bLeave)
                {
                    onPath[node.m_Zone]--;
                    continue;
                }
                if (item.m_iNode != 0)
                {
                    ZoneStats& stats = _Out.m_Stats[node.m_Zone];
                    stats.m_Id = node.m_Zone;
                    stats.m_uiCalls += node.m_uiCalls;
                    stats.m_fExclusiveMs += Ms(node.m_iInclusive - node.m_iChildren);
                    stats.m_fMaxMs = std::max(stats.m_fMaxMs, Ms(node.m_iMax));
                    if (onPath[node.m_Zone] == 0)
                    {
                        stats.m_fInclusiveMs += Ms(node.m_iInclusive);
                    }
                    onPath[node.m_Zone]++;
                    const ZoneId caller = node.m_iParent > 0 ? tree[static_cast<std::size_t>(node.m_iParent)].m_Zone : kNoZone;
                    Edge& edge = _Out.m_Edges[{caller, node.m_Zone}];
                    edge.m_uiCalls += node.m_uiCalls;
                    edge.m_iTime += node.m_iInclusive;
                    stack.push_back({item.m_iNode, true});
                }
                for (const std::int32_t ichild : kids[static_cast<std::size_t>(item.m_iNode)])
                {
                    stack.push_back({ichild, false});
                }
            }
        }

        std::string ShortName(const std::string& _Name, std::size_t _uiMax = 110)
        {
            return _Name.size() <= _uiMax ? _Name : _Name.substr(0, _uiMax - 3) + "...";
        }

        void WriteTrace(const fs::path& _File, const std::vector<ThreadCapture>& _Threads,
            const std::vector<CounterSample>& _Counters, std::int64_t _iStart)
        {
            // Keep the timeline loadable: at most about two million events,
            // the longest ones.
            std::vector<std::int64_t> durations;
            for (const auto& thread : _Threads)
            {
                for (const auto& ev : thread.m_Events)
                {
                    durations.push_back(ev.m_iEnd - ev.m_iBegin);
                }
            }
            constexpr std::size_t kMaxTraceEvents = 2'000'000;
            std::int64_t iminDur = 0;
            if (durations.size() > kMaxTraceEvents)
            {
                std::nth_element(durations.begin(), durations.begin() + static_cast<std::ptrdiff_t>(kMaxTraceEvents),
                    durations.end(), std::greater<std::int64_t>());
                iminDur = durations[kMaxTraceEvents];
            }
            durations.clear();
            durations.shrink_to_fit();

            std::unordered_map<ZoneId, std::string> names;
            auto nameOf = [&](ZoneId _Id) -> const std::string&
            {
                auto it = names.find(_Id);
                if (it == names.end())
                {
                    it = names.emplace(_Id, JsonEscape(ZoneName(_Id))).first;
                }
                return it->second;
            };

            std::ofstream out(_File, std::ios::binary);
            out << "{\"displayTimeUnit\":\"ms\",\"traceEvents\":[\n";
            out << "{\"name\":\"process_name\",\"ph\":\"M\",\"pid\":1,\"args\":{\"name\":\"GitGud\"}}";
            for (const auto& thread : _Threads)
            {
                out << ",\n{\"name\":\"thread_name\",\"ph\":\"M\",\"pid\":1,\"tid\":" << thread.m_uIndex
                    << ",\"args\":{\"name\":\"" << JsonEscape(thread.m_Name) << "\"}}";
                out << ",\n{\"name\":\"thread_sort_index\",\"ph\":\"M\",\"pid\":1,\"tid\":" << thread.m_uIndex
                    << ",\"args\":{\"sort_index\":" << thread.m_uIndex << "}}";
            }
            char buf[128];
            for (const auto& thread : _Threads)
            {
                for (const auto& ev : thread.m_Events)
                {
                    if (ev.m_iEnd - ev.m_iBegin < iminDur)
                    {
                        continue;
                    }
                    std::snprintf(buf, sizeof(buf), "\",\"ph\":\"X\",\"pid\":1,\"tid\":%u,\"ts\":%.3f,\"dur\":%.3f}",
                        thread.m_uIndex, static_cast<double>(ev.m_iBegin - _iStart) / 1000.0,
                        static_cast<double>(ev.m_iEnd - ev.m_iBegin) / 1000.0);
                    out << ",\n{\"name\":\"" << nameOf(ev.m_Id) << buf;
                }
            }
            for (const auto& sample : _Counters)
            {
                std::snprintf(buf, sizeof(buf), "\",\"ph\":\"C\",\"pid\":1,\"ts\":%.3f,\"args\":{\"value\":%.3f}}",
                    static_cast<double>(sample.m_iTime - _iStart) / 1000.0, sample.m_fValue);
                out << ",\n{\"name\":\"" << JsonEscape(sample.m_Name) << buf;
            }
            out << "\n]}\n";
        }

        void WriteFolded(const fs::path& _File, const std::vector<ThreadCapture>& _Threads)
        {
            std::ofstream out(_File, std::ios::binary);
            for (const auto& thread : _Threads)
            {
                const auto& tree = thread.m_Tree;
                std::vector<std::string> paths(tree.size());
                for (std::size_t i = 1; i < tree.size(); ++i)
                {
                    const auto iparent = static_cast<std::size_t>(tree[i].m_iParent);
                    std::string name = ZoneName(tree[i].m_Zone);
                    std::replace(name.begin(), name.end(), ';', ':');
                    std::replace(name.begin(), name.end(), '\n', ' ');
                    paths[i] = (iparent == 0 ? thread.m_Name : paths[iparent]) + ";" + name;
                    const std::int64_t iself = (tree[i].m_iInclusive - tree[i].m_iChildren) / 1000;
                    if (iself > 0)
                    {
                        out << paths[i] << ' ' << iself << '\n';
                    }
                }
            }
        }

        // An interactive flame graph: one section per thread, the call tree's
        // inclusive times as widths. Click a frame to zoom into it, the top
        // bar (or Escape) to zoom out.
        void WriteFlame(const fs::path& _File, const std::vector<ThreadCapture>& _Threads, double _fSeconds)
        {
            constexpr double kWidth = 1800.0;
            constexpr double kRow = 17.0;
            std::ostringstream body;
            double y = 34.0;
            int isection = 0;
            for (const auto& thread : _Threads)
            {
                const auto& tree = thread.m_Tree;
                if (tree.size() < 2)
                {
                    continue;
                }
                const auto kids = ChildLists(tree);
                std::int64_t itotal = 0;
                for (const std::int32_t ichild : kids[0])
                {
                    itotal += tree[static_cast<std::size_t>(ichild)].m_iInclusive;
                }
                if (itotal <= 0)
                {
                    continue;
                }
                // Lay out the rows top-down from each thread's root.
                struct Item
                {
                    std::int32_t m_iNode;
                    double m_fX;
                    int m_iDepth;
                };
                int imaxDepth = 0;
                std::vector<Item> stack;
                std::vector<Item> placed;
                double fx = 0.0;
                for (const std::int32_t ichild : kids[0])
                {
                    stack.push_back({ichild, fx, 1});
                    fx += static_cast<double>(tree[static_cast<std::size_t>(ichild)].m_iInclusive) / static_cast<double>(itotal) * kWidth;
                }
                while (!stack.empty())
                {
                    const Item item = stack.back();
                    stack.pop_back();
                    const Node& node = tree[static_cast<std::size_t>(item.m_iNode)];
                    const double fw = static_cast<double>(node.m_iInclusive) / static_cast<double>(itotal) * kWidth;
                    if (fw < 0.2)
                    {
                        continue;
                    }
                    placed.push_back(item);
                    imaxDepth = std::max(imaxDepth, item.m_iDepth);
                    double fcx = item.m_fX;
                    for (const std::int32_t ichild : kids[static_cast<std::size_t>(item.m_iNode)])
                    {
                        stack.push_back({ichild, fcx, item.m_iDepth + 1});
                        fcx += static_cast<double>(tree[static_cast<std::size_t>(ichild)].m_iInclusive) / static_cast<double>(itotal) * kWidth;
                    }
                }
                body << "<g class=\"section\" data-y=\"" << y << "\">\n";
                body << Fmt("<text x=\"4\" y=\"%.1f\" class=\"title\">%s: %.1f ms in zones over %.1f s</text>\n", y + 13.0,
                    XmlEscape(thread.m_Name).c_str(), Ms(itotal), _fSeconds);
                const double fbase = y + 20.0;
                const std::string threadLabel = XmlEscape(thread.m_Name);
                body << Fmt("<g class=\"f\" data-x=\"0\" data-w=\"%.3f\" data-d=\"0\"><title>%s (all) %.2f ms</title>"
                            "<rect x=\"0\" y=\"%.1f\" width=\"%.3f\" height=\"%.1f\" fill=\"#ccc\"/>"
                            "<text x=\"3\" y=\"%.1f\">%s</text></g>\n",
                    kWidth, threadLabel.c_str(), Ms(itotal), fbase, kWidth, kRow - 1.0, fbase + 12.0, threadLabel.c_str());
                for (const Item& item : placed)
                {
                    const Node& node = tree[static_cast<std::size_t>(item.m_iNode)];
                    const double fw = static_cast<double>(node.m_iInclusive) / static_cast<double>(itotal) * kWidth;
                    const std::string name = ZoneName(node.m_Zone);
                    const bool blua = name.find(".lua:") != std::string::npos;
                    const bool bc = name.rfind("[C]", 0) == 0;
                    unsigned int uhash = 2166136261u;
                    for (const char c : name)
                    {
                        uhash = (uhash ^ static_cast<unsigned char>(c)) * 16777619u;
                    }
                    const int ivary = static_cast<int>(uhash % 60);
                    std::string colour = blua  ? Fmt("rgb(%d,%d,%d)", 90 + ivary, 190 + ivary / 2, 90 + ivary / 3)
                                         : bc ? Fmt("rgb(%d,%d,%d)", 80 + ivary / 2, 160 + ivary, 210)
                                              : Fmt("rgb(%d,%d,%d)", 225, 110 + ivary * 2, 40 + ivary / 2);
                    const double fy = fbase + kRow * item.m_iDepth;
                    const std::string label = XmlEscape(name);
                    body << Fmt("<g class=\"f\" data-x=\"%.3f\" data-w=\"%.3f\" data-d=\"%d\"><title>", item.m_fX, fw, item.m_iDepth)
                         << label
                         << Fmt("\n%.2f ms inclusive (%.1f%%), %.2f ms self, %llu calls, longest %.2f ms</title>", Ms(node.m_iInclusive),
                                100.0 * static_cast<double>(node.m_iInclusive) / static_cast<double>(itotal),
                                Ms(node.m_iInclusive - node.m_iChildren), static_cast<unsigned long long>(node.m_uiCalls), Ms(node.m_iMax))
                         << Fmt("<rect x=\"%.3f\" y=\"%.1f\" width=\"%.3f\" height=\"%.1f\" fill=\"%s\"/>", item.m_fX, fy, fw, kRow - 1.0,
                                colour.c_str())
                         << Fmt("<text x=\"%.3f\" y=\"%.1f\"></text><desc>", item.m_fX + 3.0, fy + 12.0) << label << "</desc></g>\n";
                }
                body << "</g>\n";
                y = fbase + kRow * (imaxDepth + 2) + 10.0;
                ++isection;
            }
            std::ofstream out(_File, std::ios::binary);
            out << Fmt("<?xml version=\"1.0\" standalone=\"no\"?>\n"
                       "<svg version=\"1.1\" width=\"%.0f\" height=\"%.0f\" xmlns=\"http://www.w3.org/2000/svg\" onload=\"init()\">\n",
                kWidth + 4, y + 10);
            out << R"(<style>
text { font-family: Consolas, monospace; font-size: 11px; pointer-events: none; }
.title { font-size: 13px; font-weight: bold; }
.f:hover rect { stroke: #000; stroke-width: 0.5; }
rect { rx: 2; }
</style>
<script><![CDATA[
var W = )" << kWidth
                << R"(;
function frames(sec) { return sec.querySelectorAll('.f'); }
function label(g) {
  var r = g.querySelector('rect'), t = g.querySelector('text'), d = g.querySelector('desc');
  var w = parseFloat(r.getAttribute('width'));
  var name = d ? d.textContent : t.textContent;
  var n = Math.floor((w - 6) / 6.6);
  t.textContent = n < 3 ? '' : (name.length <= n ? name : name.substring(0, n - 2) + '..');
  t.setAttribute('x', parseFloat(r.getAttribute('x')) + 3);
}
function show(sec, x0, w0, d0) {
  frames(sec).forEach(function (g) {
    var x = parseFloat(g.dataset.x), w = parseFloat(g.dataset.w), d = parseInt(g.dataset.d);
    var r = g.querySelector('rect');
    if (d < d0 && x <= x0 + 0.001 && x + w >= x0 + w0 - 0.001) { r.setAttribute('x', 0); r.setAttribute('width', W); g.style.display = ''; g.style.opacity = 0.6; }
    else if (d >= d0 && x >= x0 - 0.001 && x + w <= x0 + w0 + 0.001) {
      var nx = (x - x0) / w0 * W, nw = w / w0 * W;
      r.setAttribute('x', nx); r.setAttribute('width', nw); g.style.display = nw < 0.2 ? 'none' : ''; g.style.opacity = 1;
    } else { g.style.display = 'none'; }
    label(g);
  });
}
function init() {
  document.querySelectorAll('.section').forEach(function (sec) {
    frames(sec).forEach(function (g) {
      label(g);
      g.addEventListener('click', function () { show(sec, parseFloat(g.dataset.x), parseFloat(g.dataset.w), parseInt(g.dataset.d)); });
    });
  });
  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') document.querySelectorAll('.section').forEach(function (sec) { show(sec, 0, W, 0); });
  });
}
]]></script>
)";
            out << Fmt("<text x=\"4\" y=\"18\" class=\"title\">GitGud profile, %.1f s. Click a frame to zoom, Escape to reset. "
                       "Orange: C++, green: Lua, blue: Lua calling C.</text>\n",
                _fSeconds);
            out << body.str() << "</svg>\n";
        }

        struct FrameRow
        {
            std::int64_t m_iBegin;
            std::int64_t m_iEnd;
            std::uint32_t m_uDepth;
        };

        void WriteReport(const fs::path& _File, const std::vector<ThreadCapture>& _Threads,
            const std::vector<CounterSample>& _Counters, std::int64_t _iStart, std::int64_t _iEnd,
            std::vector<ZoneStats>& _StatsOut)
        {
            std::ofstream out(_File, std::ios::binary);
            const double fseconds = Ms(_iEnd - _iStart) / 1000.0;
            out << Fmt("GitGud performance capture: %.2f s, %zu threads\n", fseconds, _Threads.size());
            std::size_t uievents = 0;
            for (const auto& thread : _Threads)
            {
                uievents += thread.m_Events.size();
            }
            out << Fmt("%zu timeline events kept\n\n", uievents);

            // Frames of the UI thread.
            const ZoneId frameId = Intern("Frame");
            for (const auto& thread : _Threads)
            {
                if (thread.m_Name != "UI")
                {
                    continue;
                }
                std::vector<FrameRow> frames;
                for (const auto& ev : thread.m_Events)
                {
                    if (ev.m_Id == frameId)
                    {
                        frames.push_back({ev.m_iBegin, ev.m_iEnd, ev.m_uDepth});
                    }
                }
                if (frames.empty())
                {
                    break;
                }
                // Waiting for the display in the buffer swap isn't work:
                // frame times leave it out.
                const ZoneId swapId = Intern("Swap (vsync wait)");
                std::sort(frames.begin(), frames.end(), [](const FrameRow& _A, const FrameRow& _B) { return _A.m_iBegin < _B.m_iBegin; });
                std::vector<std::int64_t> waits(frames.size(), 0);
                for (const auto& ev : thread.m_Events)
                {
                    if (ev.m_Id != swapId)
                    {
                        continue;
                    }
                    auto it = std::upper_bound(frames.begin(), frames.end(), ev.m_iBegin,
                        [](std::int64_t _T, const FrameRow& _F) { return _T < _F.m_iBegin; });
                    if (it != frames.begin() && ev.m_iEnd <= std::prev(it)->m_iEnd)
                    {
                        waits[static_cast<std::size_t>(std::prev(it) - frames.begin())] += ev.m_iEnd - ev.m_iBegin;
                    }
                }
                double fwait = 0.0;
                for (std::size_t i = 0; i < frames.size(); ++i)
                {
                    frames[i].m_iEnd -= waits[i]; // from here on, a frame's length is its work
                    fwait += Ms(waits[i]);
                }
                std::vector<double> times;
                double fbusy = 0.0;
                for (const auto& frame : frames)
                {
                    times.push_back(Ms(frame.m_iEnd - frame.m_iBegin));
                    fbusy += times.back();
                }
                std::sort(times.begin(), times.end());
                auto pct = [&](double _fP)
                {
                    return times[std::min(times.size() - 1, static_cast<std::size_t>(_fP * static_cast<double>(times.size())))];
                };
                std::size_t uover16 = 0, uover50 = 0, uover200 = 0, uover1000 = 0;
                for (const double f : times)
                {
                    uover16 += f >= 16.7;
                    uover50 += f >= 50.0;
                    uover200 += f >= 200.0;
                    uover1000 += f >= 1000.0;
                }
                out << "== UI frames (main loop passes, not counting the waits for input and the display)\n";
                out << Fmt("%zu frames, busy %.1f ms of %.1f s (%.1f%%), %.1f ms more waiting for the display\n",
                    frames.size(), fbusy, fseconds, fseconds > 0 ? fbusy / (fseconds * 10.0) : 0.0, fwait);
                out << Fmt("median %.2f ms, p95 %.2f ms, p99 %.2f ms, max %.1f ms\n", pct(0.5), pct(0.95), pct(0.99), times.back());
                out << Fmt("over 16.7 ms: %zu, over 50 ms: %zu, over 200 ms: %zu, over 1 s: %zu\n\n", uover16, uover50, uover200,
                    uover1000);

                // The slowest frames, each split into where its own time went.
                std::vector<Event> sorted = thread.m_Events;
                std::sort(sorted.begin(), sorted.end(), [](const Event& _A, const Event& _B)
                    { return _A.m_iBegin != _B.m_iBegin ? _A.m_iBegin < _B.m_iBegin : _A.m_uDepth < _B.m_uDepth; });
                std::sort(frames.begin(), frames.end(),
                    [](const FrameRow& _A, const FrameRow& _B) { return _A.m_iEnd - _A.m_iBegin > _B.m_iEnd - _B.m_iBegin; });
                out << "== Slowest frames, by where their time went (self time per zone)\n";
                const std::size_t ushow = std::min<std::size_t>(frames.size(), 20);
                for (std::size_t i = 0; i < ushow; ++i)
                {
                    const FrameRow& frame = frames[i];
                    out << Fmt("-- frame at %.3f s: %.1f ms\n", Ms(frame.m_iBegin - _iStart) / 1000.0, Ms(frame.m_iEnd - frame.m_iBegin));
                    auto it = std::lower_bound(sorted.begin(), sorted.end(), frame.m_iBegin,
                        [](const Event& _E, std::int64_t _T) { return _E.m_iBegin < _T; });
                    std::unordered_map<ZoneId, std::int64_t> self;
                    std::unordered_map<ZoneId, std::uint64_t> calls;
                    std::vector<const Event*> enclosing;
                    for (; it != sorted.end() && it->m_iBegin < frame.m_iEnd; ++it)
                    {
                        if (it->m_uDepth <= frame.m_uDepth || it->m_iEnd > frame.m_iEnd)
                        {
                            continue;
                        }
                        while (!enclosing.empty() && (enclosing.back()->m_iEnd <= it->m_iBegin || enclosing.back()->m_uDepth >= it->m_uDepth))
                        {
                            enclosing.pop_back();
                        }
                        const std::int64_t idur = it->m_iEnd - it->m_iBegin;
                        self[it->m_Id] += idur;
                        calls[it->m_Id]++;
                        if (!enclosing.empty())
                        {
                            self[enclosing.back()->m_Id] -= idur;
                        }
                        enclosing.push_back(&*it);
                    }
                    std::vector<std::pair<std::int64_t, ZoneId>> rows;
                    for (const auto& [id, ins] : self)
                    {
                        rows.emplace_back(ins, id);
                    }
                    std::sort(rows.rbegin(), rows.rend());
                    for (std::size_t r = 0; r < rows.size() && r < 12; ++r)
                    {
                        if (Ms(rows[r].first) < 0.05)
                        {
                            break;
                        }
                        out << Fmt("   %9.2f ms  %6llu x  ", Ms(rows[r].first), static_cast<unsigned long long>(calls[rows[r].second]))
                            << ShortName(ZoneName(rows[r].second)) << '\n';
                    }
                }
                out << '\n';
                break;
            }

            // Zones over the whole capture.
            for (const auto& thread : _Threads)
            {
                Analysis analysis;
                Analyse(thread, analysis);
                if (analysis.m_Stats.empty())
                {
                    continue;
                }
                std::vector<ZoneStats> stats;
                for (auto& [id, zone] : analysis.m_Stats)
                {
                    zone.m_Name = ZoneName(id);
                    stats.push_back(zone);
                }
                if (thread.m_Name == "UI")
                {
                    _StatsOut = stats;
                    std::sort(_StatsOut.begin(), _StatsOut.end(),
                        [](const ZoneStats& _A, const ZoneStats& _B) { return _A.m_fExclusiveMs > _B.m_fExclusiveMs; });
                }
                out << "== Thread '" << thread.m_Name << "'\n";
                auto table = [&](const char* _szTitle, auto _Key)
                {
                    std::sort(stats.begin(), stats.end(), [&](const ZoneStats& _A, const ZoneStats& _B) { return _Key(_A) > _Key(_B); });
                    out << "-- " << _szTitle << "\n";
                    out << "   inclusive ms    self ms      calls    avg ms    max ms  zone\n";
                    for (std::size_t i = 0; i < stats.size() && i < 40; ++i)
                    {
                        const ZoneStats& z = stats[i];
                        if (_Key(z) <= 0.0)
                        {
                            break;
                        }
                        out << Fmt("   %12.2f %10.2f %10llu %9.3f %9.2f  ", z.m_fInclusiveMs, z.m_fExclusiveMs,
                                   static_cast<unsigned long long>(z.m_uiCalls),
                                   z.m_uiCalls ? z.m_fInclusiveMs / static_cast<double>(z.m_uiCalls) : 0.0, z.m_fMaxMs)
                            << ShortName(z.m_Name) << '\n';
                    }
                };
                table("by self time", [](const ZoneStats& _Z) { return _Z.m_fExclusiveMs; });
                table("by inclusive time", [](const ZoneStats& _Z) { return _Z.m_fInclusiveMs; });

                // Callers and callees of the zones with the most self time.
                std::sort(stats.begin(), stats.end(),
                    [](const ZoneStats& _A, const ZoneStats& _B) { return _A.m_fExclusiveMs > _B.m_fExclusiveMs; });
                out << "-- callers and callees (the 15 zones with the most self time)\n";
                for (std::size_t i = 0; i < stats.size() && i < 15; ++i)
                {
                    const ZoneId id = stats[i].m_Id;
                    out << "   " << ShortName(stats[i].m_Name) << Fmt("  (self %.2f ms)\n", stats[i].m_fExclusiveMs);
                    std::vector<std::pair<std::int64_t, std::string>> callers, callees;
                    for (const auto& [key, edge] : analysis.m_Edges)
                    {
                        if (key.second == id)
                        {
                            callers.emplace_back(edge.m_iTime,
                                Fmt("%10.2f ms %8llu x  <- ", Ms(edge.m_iTime), static_cast<unsigned long long>(edge.m_uiCalls)) +
                                    ShortName(key.first == kNoZone ? "(thread root)" : ZoneName(key.first)));
                        }
                        if (key.first == id)
                        {
                            callees.emplace_back(edge.m_iTime,
                                Fmt("%10.2f ms %8llu x  -> ", Ms(edge.m_iTime), static_cast<unsigned long long>(edge.m_uiCalls)) +
                                    ShortName(ZoneName(key.second)));
                        }
                    }
                    std::sort(callers.rbegin(), callers.rend());
                    std::sort(callees.rbegin(), callees.rend());
                    for (std::size_t c = 0; c < callers.size() && c < 6; ++c)
                    {
                        out << "     " << callers[c].second << '\n';
                    }
                    for (std::size_t c = 0; c < callees.size() && c < 8; ++c)
                    {
                        out << "     " << callees[c].second << '\n';
                    }
                }
                out << '\n';
            }

            // Counters (memory) over time: first, last, lowest, highest.
            std::map<std::string, std::vector<std::pair<std::int64_t, double>>> series;
            for (const auto& sample : _Counters)
            {
                series[sample.m_Name].emplace_back(sample.m_iTime, sample.m_fValue);
            }
            if (!series.empty())
            {
                out << "== Counters\n";
                for (const auto& [name, values] : series)
                {
                    double flo = values.front().second, fhi = flo;
                    for (const auto& v : values)
                    {
                        flo = std::min(flo, v.second);
                        fhi = std::max(fhi, v.second);
                    }
                    out << Fmt("   %-28s first %10.1f  last %10.1f  low %10.1f  high %10.1f  (%zu samples)\n", name.c_str(),
                        values.front().second, values.back().second, flo, fhi, values.size());
                }
            }
        }

        std::string TimeStamp()
        {
            const std::time_t now = std::time(nullptr);
            std::tm tm{};
#if defined(_WIN32)
            localtime_s(&tm, &now);
#else
            localtime_r(&now, &tm);
#endif
            char buf[32];
            std::strftime(buf, sizeof(buf), "%Y%m%d-%H%M%S", &tm);
            return buf;
        }

    } // namespace

    bool& HooksOff()
    {
        thread_local bool s_bOff = false;
        return s_bOff;
    }

    namespace
    {
        // The profiler's own code: the instrument hooks stay out (HooksOff).
        struct Quiet
        {
            bool& m_bOff = HooksOff();
            const bool m_bWas = m_bOff;
            Quiet() { m_bOff = true; }
            ~Quiet() { m_bOff = m_bWas; }
            Quiet(const Quiet&) = delete;
            Quiet& operator=(const Quiet&) = delete;
        };
    } // namespace

    // --- Names -------------------------------------------------------------
    ZoneId Intern(std::string_view _Name)
    {
        const Quiet quiet;
        Names& names = TheNames();
        std::lock_guard<std::mutex> lock(names.m_Mutex);
        std::string key(_Name);
        const auto it = names.m_ByName.find(key);
        if (it != names.m_ByName.end())
        {
            return it->second;
        }
        const auto id = static_cast<ZoneId>(names.m_Names.size());
        names.m_Names.push_back(key);
        names.m_Addresses.push_back(0);
        names.m_Resolved.push_back(true);
        names.m_ByName.emplace(std::move(key), id);
        return id;
    }

    ZoneId InternAddress(std::uintptr_t _Address)
    {
        const Quiet quiet;
        Names& names = TheNames();
        std::lock_guard<std::mutex> lock(names.m_Mutex);
        const auto it = names.m_ByAddress.find(_Address);
        if (it != names.m_ByAddress.end())
        {
            return it->second;
        }
        const auto id = static_cast<ZoneId>(names.m_Names.size());
        names.m_Names.push_back(Fmt("0x%llx", static_cast<unsigned long long>(_Address)));
        names.m_Addresses.push_back(_Address);
        names.m_Resolved.push_back(false);
        names.m_ByAddress.emplace(_Address, id);
        return id;
    }

    std::string ZoneName(ZoneId _Id)
    {
        const Quiet quiet;
        Names& names = TheNames();
        std::uintptr_t address = 0;
        {
            std::lock_guard<std::mutex> lock(names.m_Mutex);
            if (_Id >= names.m_Names.size())
            {
                return "?";
            }
            if (names.m_Resolved[_Id])
            {
                return names.m_Names[_Id];
            }
            address = names.m_Addresses[_Id];
        }
        std::string name = Symbolize(address, false);
        std::lock_guard<std::mutex> lock(names.m_Mutex);
        names.m_Names[_Id] = name;
        names.m_Resolved[_Id] = true;
        return name;
    }

    void RenameZone(ZoneId _Id, const std::string& _Name)
    {
        const Quiet quiet;
        Names& names = TheNames();
        std::lock_guard<std::mutex> lock(names.m_Mutex);
        if (_Id < names.m_Names.size())
        {
            names.m_Names[_Id] = _Name;
            names.m_Resolved[_Id] = true;
            names.m_ByName.emplace(_Name, _Id);
        }
    }

    ZoneId Site::Id()
    {
        const Quiet quiet;
        ZoneId id = m_Id.load(std::memory_order_relaxed);
        if (id == kNoZone)
        {
            id = Intern(m_szName);
            m_Id.store(id, std::memory_order_relaxed);
        }
        return id;
    }

    // --- Zones -------------------------------------------------------------
    void Begin(ZoneId _Id)
    {
        const Quiet quiet;
        ThreadData& td = Td();
        const int idepth = td.m_Activity.m_iDepth.load(std::memory_order_relaxed);
        if (idepth < Activity::kMax)
        {
            td.m_Activity.m_aZones[idepth] = _Id;
        }
        td.m_Activity.m_iDepth.store(idepth + 1, std::memory_order_release);
        if (Capturing())
        {
            BeginCaptured(td, _Id, idepth);
        }
    }

    void End()
    {
        const Quiet quiet;
        ThreadData& td = Td();
        const int idepth = td.m_Activity.m_iDepth.load(std::memory_order_relaxed) - 1;
        if (idepth < 0)
        {
            return;
        }
        td.m_Activity.m_iDepth.store(idepth, std::memory_order_release);
        while (!td.m_Open.empty() && td.m_Open.back().m_iDepth > idepth)
        {
            td.m_Open.pop_back();
        }
        if (!td.m_Open.empty() && td.m_Open.back().m_iDepth == idepth)
        {
            const Open open = td.m_Open.back();
            td.m_Open.pop_back();
            if (Capturing())
            {
                EndCaptured(td, open);
            }
        }
    }

    int Depth()
    {
        return Td().m_Activity.m_iDepth.load(std::memory_order_relaxed);
    }

    void EndTo(int _iDepth)
    {
        while (Depth() > std::max(0, _iDepth))
        {
            End();
        }
    }

    void SetThreadName(const std::string& _Name)
    {
        const Quiet quiet;
        ThreadData& td = Td();
        std::lock_guard<std::mutex> lock(td.m_Mutex);
        td.m_Name = _Name;
    }

    Activity* ThreadActivity()
    {
        const Quiet quiet;
        return &Td().m_Activity;
    }

    void Counter(const char* _szName, double _fValue)
    {
        const Quiet quiet;
        if (!Capturing())
        {
            return;
        }
        std::lock_guard<std::mutex> lock(g_CounterMutex);
        g_Counters.push_back({_szName, NowNs(), _fValue});
    }

    // --- Capture -----------------------------------------------------------
    bool StartCapture(const CaptureOptions& _Options)
    {
        const Quiet quiet;
        if (Capturing())
        {
            return false;
        }
        g_Options = _Options;
        {
            std::lock_guard<std::mutex> lock(g_CounterMutex);
            g_Counters.clear();
        }
        g_iCaptureStart.store(NowNs());
        g_uGen.fetch_add(1, std::memory_order_acq_rel);
        detail::g_bCapturing.store(true, std::memory_order_release);
        return true;
    }

    bool LuaCallsWanted()
    {
        return Capturing() && g_Options.m_bLuaCalls;
    }

    double CaptureSeconds()
    {
        return Capturing() ? Ms(NowNs() - g_iCaptureStart.load()) / 1000.0 : 0.0;
    }

    std::string StopCapture(const std::string& _Directory)
    {
        const Quiet quiet;
        if (!Capturing())
        {
            return {};
        }
        detail::g_bCapturing.store(false, std::memory_order_release);
        const std::int64_t iend = NowNs();
        const std::int64_t istart = g_iCaptureStart.load();
        const std::uint32_t ugen = g_uGen.load();

        std::vector<ThreadCapture> threads;
        {
            Registry& reg = TheRegistry();
            std::lock_guard<std::mutex> lock(reg.m_Mutex);
            for (const auto& td : reg.m_Threads)
            {
                std::lock_guard<std::mutex> tlock(td->m_Mutex);
                if (td->m_uGen != ugen || td->m_Tree.size() < 2)
                {
                    continue;
                }
                ThreadCapture capture;
                capture.m_uIndex = td->m_uIndex;
                capture.m_uiOsId = td->m_uiOsId;
                capture.m_Name = td->m_Name;
                capture.m_Events = std::move(td->m_Events);
                capture.m_Tree = std::move(td->m_Tree);
                td->m_Events = {};
                td->m_Tree = {};
                td->m_Children = {};
                td->m_uGen = 0;
                threads.push_back(std::move(capture));
            }
        }
        // The UI thread first.
        std::stable_sort(threads.begin(), threads.end(),
            [](const ThreadCapture& _A, const ThreadCapture& _B) { return (_A.m_Name == "UI") > (_B.m_Name == "UI"); });
        std::vector<CounterSample> counters;
        {
            std::lock_guard<std::mutex> lock(g_CounterMutex);
            counters.swap(g_Counters);
        }

        std::error_code ec;
        const fs::path dir = fs::u8path(_Directory) / ("profile-" + TimeStamp());
        fs::create_directories(dir, ec);
        if (ec)
        {
            return {};
        }
        std::vector<ZoneStats> stats;
        WriteReport(dir / "report.txt", threads, counters, istart, iend, stats);
        WriteFlame(dir / "flame.svg", threads, Ms(iend - istart) / 1000.0);
        WriteFolded(dir / "folded.txt", threads);
        WriteTrace(dir / "trace.json", threads, counters, istart);
        {
            std::lock_guard<std::mutex> lock(g_LastMutex);
            g_LastStats = std::move(stats);
        }
        return dir.u8string();
    }

    namespace
    {
        std::atomic<int> g_iRequest{0};
        std::mutex g_FolderMutex;
        std::string g_LastFolder;
    } // namespace

    void RequestCapture(CaptureRequest _Request)
    {
        g_iRequest.store(static_cast<int>(_Request));
    }

    CaptureRequest TakeCaptureRequest()
    {
        return static_cast<CaptureRequest>(g_iRequest.exchange(0));
    }

    void SetLastCaptureFolder(const std::string& _Folder)
    {
        const Quiet quiet;
        std::lock_guard<std::mutex> lock(g_FolderMutex);
        g_LastFolder = _Folder;
    }

    std::string LastCaptureFolder()
    {
        const Quiet quiet;
        std::lock_guard<std::mutex> lock(g_FolderMutex);
        return g_LastFolder;
    }

    std::vector<ZoneStats> LastCaptureStats()
    {
        const Quiet quiet;
        std::lock_guard<std::mutex> lock(g_LastMutex);
        return g_LastStats;
    }

    // --- Symbols -------------------------------------------------------------
    std::string Symbolize(std::uintptr_t _Address, bool _bWithLine)
    {
        const Quiet quiet;
#if defined(_WIN32)
        static std::mutex s_Mutex;
        static bool s_bReady = false;
        std::lock_guard<std::mutex> lock(s_Mutex);
        HANDLE hprocess = GetCurrentProcess();
        if (!s_bReady)
        {
            SymSetOptions(SymGetOptions() | SYMOPT_DEFERRED_LOADS | SYMOPT_LOAD_LINES | SYMOPT_UNDNAME);
            // The program's folder first: its symbols lie beside it.
            char exePath[MAX_PATH] = {};
            GetModuleFileNameA(nullptr, exePath, MAX_PATH);
            if (char* szslash = std::strrchr(exePath, '\\'))
            {
                *szslash = '\0';
            }
            if (!SymInitialize(hprocess, exePath, TRUE))
            {
                SymSetSearchPath(hprocess, exePath);
                SymRefreshModuleList(hprocess);
            }
            s_bReady = true;
        }
        char buffer[sizeof(SYMBOL_INFO) + MAX_SYM_NAME] = {};
        auto* psymbol = reinterpret_cast<SYMBOL_INFO*>(buffer);
        psymbol->SizeOfStruct = sizeof(SYMBOL_INFO);
        psymbol->MaxNameLen = MAX_SYM_NAME;
        DWORD64 displacement = 0;
        std::string out;
        if (SymFromAddr(hprocess, _Address, &displacement, psymbol))
        {
            out = psymbol->Name;
        }
        else
        {
            HMODULE hmodule = nullptr;
            char modulePath[MAX_PATH] = {};
            if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                    reinterpret_cast<LPCSTR>(_Address), &hmodule) &&
                GetModuleFileNameA(hmodule, modulePath, MAX_PATH))
            {
                const char* szbase = std::strrchr(modulePath, '\\');
                out = Fmt("%s+0x%llx", szbase ? szbase + 1 : modulePath,
                    static_cast<unsigned long long>(_Address - reinterpret_cast<std::uintptr_t>(hmodule)));
            }
            else
            {
                out = Fmt("0x%llx", static_cast<unsigned long long>(_Address));
            }
        }
        if (_bWithLine)
        {
            IMAGEHLP_LINE64 line = {};
            line.SizeOfStruct = sizeof(line);
            DWORD lineDisplacement = 0;
            if (SymGetLineFromAddr64(hprocess, _Address, &lineDisplacement, &line))
            {
                const char* szbase = std::strrchr(line.FileName, '\\');
                out += Fmt("  (%s:%lu)", szbase ? szbase + 1 : line.FileName, line.LineNumber);
            }
        }
        return out;
#else
        (void)_bWithLine;
        Dl_info info{};
        if (dladdr(reinterpret_cast<void*>(_Address), &info) && info.dli_sname)
        {
            return info.dli_sname;
        }
        return Fmt("0x%llx", static_cast<unsigned long long>(_Address));
#endif
    }

} // namespace gitgud::prof
