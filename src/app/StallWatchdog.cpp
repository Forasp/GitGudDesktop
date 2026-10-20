#include "app/StallWatchdog.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdarg>
#include <cstdio>
#include <ctime>
#include <map>
#include <mutex>
#include <set>
#include <thread>
#include <unordered_map>
#include <vector>

#include "app/Profiler.h"

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

#include <psapi.h>
#elif defined(__APPLE__)
#include <mach/mach.h>
#endif

namespace gitgud::prof
{
    namespace
    {
        using Clock = std::chrono::steady_clock;

        std::int64_t NowNs()
        {
            return std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now().time_since_epoch()).count();
        }

        constexpr int kMaxFrames = 64;
        constexpr int kMaxZones = 48;
        constexpr int kSampleEveryMs = 50;

        struct Sample
        {
            std::int64_t m_iTime = 0;
            int m_iFrames = 0;
            std::uintptr_t m_aFrames[kMaxFrames] = {};
            int m_iZones = 0;
            int m_iZoneDepth = 0;
            ZoneId m_aZones[kMaxZones] = {};
        };

        struct State
        {
            std::atomic<std::int64_t> m_iBusySince{0};
            std::atomic<std::uint64_t> m_uiPass{0};
            std::atomic<std::int64_t> m_iLastPassBegin{0};
            std::atomic<std::int64_t> m_iLastPassEnd{0};
            std::atomic<std::uint64_t> m_uiLastPass{0};
            std::atomic<int> m_iThresholdMs{200};
            std::atomic<bool> m_bLuaWanted{false};
            std::atomic<double> m_fLuaKb{0.0};
            std::atomic<std::uint64_t> m_uFrames{0};       // main-window frames presented
            std::atomic<std::uint64_t> m_uFailedFrames{0}; // of those, the swap failed
            std::atomic<std::int64_t> m_iLastFrame{0};     // when the last one was (NowNs)
            std::atomic<int> m_iStalls{0};
            std::atomic<bool> m_bStop{false};
            std::atomic<LuaTraceRequest> m_pfnLuaRequest{nullptr};

            Activity* m_pActivity = nullptr;
            std::string m_LogPath;
            std::thread m_Thread;
            std::mutex m_WakeMutex;
            std::condition_variable m_Wake;
#if defined(_WIN32)
            HANDLE m_hThread = nullptr;
#endif
            std::mutex m_TraceMutex;
            std::vector<std::pair<std::int64_t, std::string>> m_LuaTraces;
            std::mutex m_ReportMutex;
            std::string m_LastReport;
        };

        State& S()
        {
            static State* s_pState = new State();
            return *s_pState;
        }

        std::string Fmt(const char* _szFormat, ...)
        {
            char buf[2048];
            va_list args;
            va_start(args, _szFormat);
            std::vsnprintf(buf, sizeof(buf), _szFormat, args);
            va_end(args);
            return buf;
        }

        std::string WallClock()
        {
            const auto now = std::chrono::system_clock::now();
            const std::time_t t = std::chrono::system_clock::to_time_t(now);
            const int ims = static_cast<int>(
                std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()).count() % 1000);
            std::tm tm{};
#if defined(_WIN32)
            localtime_s(&tm, &t);
#else
            localtime_r(&t, &tm);
#endif
            char buf[48];
            std::strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", &tm);
            return Fmt("%s.%03d", buf, ims);
        }

        void AppendLog(const std::string& _Text)
        {
            State& s = S();
            if (s.m_LogPath.empty())
            {
                return;
            }
#if defined(_WIN32)
            std::wstring wide(static_cast<std::size_t>(MultiByteToWideChar(CP_UTF8, 0, s.m_LogPath.c_str(), -1, nullptr, 0)), L'\0');
            MultiByteToWideChar(CP_UTF8, 0, s.m_LogPath.c_str(), -1, wide.data(), static_cast<int>(wide.size()));
            FILE* pfile = _wfopen(wide.c_str(), L"ab");
#else
            FILE* pfile = std::fopen(s.m_LogPath.c_str(), "ab");
#endif
            if (pfile)
            {
                std::fwrite(_Text.data(), 1, _Text.size(), pfile);
                std::fclose(pfile);
            }
        }

#if defined(_WIN32) && defined(_M_X64)
        // Walk a suspended thread's stack from its context. Nothing here may
        // allocate or lock: the thread could be holding the heap's lock.
        int WalkStack(CONTEXT& _Ctx, std::uintptr_t* _pFrames, int _iMax)
        {
            int icount = 0;
            __try
            {
                while (icount < _iMax && _Ctx.Rip != 0)
                {
                    _pFrames[icount++] = static_cast<std::uintptr_t>(_Ctx.Rip);
                    DWORD64 imageBase = 0;
                    PRUNTIME_FUNCTION pentry = RtlLookupFunctionEntry(_Ctx.Rip, &imageBase, nullptr);
                    if (!pentry)
                    {
                        // A leaf function: the return address is on top.
                        _Ctx.Rip = *reinterpret_cast<DWORD64*>(_Ctx.Rsp);
                        _Ctx.Rsp += 8;
                    }
                    else
                    {
                        PVOID phandlerData = nullptr;
                        DWORD64 establisher = 0;
                        RtlVirtualUnwind(UNW_FLAG_NHANDLER, imageBase, _Ctx.Rip, pentry, &_Ctx, &phandlerData,
                            &establisher, nullptr);
                    }
                }
            }
            __except (EXCEPTION_EXECUTE_HANDLER)
            {
            }
            return icount;
        }
#endif

        bool TakeSample(Sample& _Sample)
        {
            State& s = S();
            _Sample.m_iTime = NowNs();
#if defined(_WIN32) && defined(_M_X64)
            if (!s.m_hThread || SuspendThread(s.m_hThread) == static_cast<DWORD>(-1))
            {
                return false;
            }
            CONTEXT ctx{};
            ctx.ContextFlags = CONTEXT_FULL;
            if (GetThreadContext(s.m_hThread, &ctx))
            {
                _Sample.m_iFrames = WalkStack(ctx, _Sample.m_aFrames, kMaxFrames);
            }
#endif
            if (s.m_pActivity)
            {
                const int idepth = s.m_pActivity->m_iDepth.load(std::memory_order_acquire);
                _Sample.m_iZoneDepth = idepth;
                _Sample.m_iZones = std::min({idepth, kMaxZones, Activity::kMax});
                for (int i = 0; i < _Sample.m_iZones; ++i)
                {
                    _Sample.m_aZones[i] = s.m_pActivity->m_aZones[i];
                }
            }
#if defined(_WIN32) && defined(_M_X64)
            ResumeThread(s.m_hThread);
#endif
            return true;
        }

        std::string ZonePath(const Sample& _Sample)
        {
            std::string path;
            for (int i = 0; i < _Sample.m_iZones; ++i)
            {
                path += (i ? " > " : "") + ZoneName(_Sample.m_aZones[i]);
            }
            if (_Sample.m_iZoneDepth > _Sample.m_iZones)
            {
                path += Fmt(" > ... (%d deeper)", _Sample.m_iZoneDepth - _Sample.m_iZones);
            }
            return path.empty() ? "(no zone open)" : path;
        }

        // A function's name for a code address, cached for this report.
        struct Symbols
        {
            std::unordered_map<std::uintptr_t, std::string> m_Names;
            const std::string& Function(std::uintptr_t _Address)
            {
                auto it = m_Names.find(_Address);
                if (it == m_Names.end())
                {
                    // A return address points just past the call.
                    it = m_Names.emplace(_Address, Symbolize(_Address > 0 ? _Address - 1 : 0, false)).first;
                }
                return it->second;
            }
        };

        std::string Describe(const std::vector<Sample>& _Samples, std::int64_t _iBegin, std::int64_t _iEnd, bool _bEnded,
            const std::vector<std::pair<std::int64_t, std::string>>& _LuaTraces)
        {
            std::string out = Fmt("== stall at %s: UI thread busy %.0f ms%s, %zu samples\n", WallClock().c_str(),
                static_cast<double>(_iEnd - _iBegin) / 1e6, _bEnded ? "" : " (still blocked)", _Samples.size());
            if (_Samples.empty())
            {
                return out;
            }
            out += "zones at first sample: " + ZonePath(_Samples.front()) + "\n";
            // How often each zone path held over the stall.
            std::map<std::string, int> paths;
            for (const Sample& sample : _Samples)
            {
                paths[ZonePath(sample)]++;
            }
            if (paths.size() > 1)
            {
                std::vector<std::pair<int, std::string>> rows;
                for (const auto& [path, icount] : paths)
                {
                    rows.emplace_back(icount, path);
                }
                std::sort(rows.rbegin(), rows.rend());
                out += "zones over the stall:\n";
                for (std::size_t i = 0; i < rows.size() && i < 8; ++i)
                {
                    out += Fmt("  %4d  ", rows[i].first) + rows[i].second + "\n";
                }
            }
            if (!_LuaTraces.empty())
            {
                // The distinct tracebacks, most frequent first.
                std::map<std::string, int> traces;
                for (const auto& [itime, trace] : _LuaTraces)
                {
                    traces[trace]++;
                }
                std::vector<std::pair<int, std::string>> rows;
                for (const auto& [trace, icount] : traces)
                {
                    rows.emplace_back(icount, trace);
                }
                std::sort(rows.rbegin(), rows.rend());
                out += Fmt("lua (%zu tracebacks taken while it ran Lua):\n", _LuaTraces.size());
                for (std::size_t i = 0; i < rows.size() && i < 3; ++i)
                {
                    out += Fmt("  [%d x] ", rows[i].first) + rows[i].second + "\n";
                }
            }
            Symbols symbols;
            const Sample& first = _Samples.front();
            if (first.m_iFrames > 0)
            {
                out += "native stack at first sample:\n";
                for (int i = 0; i < first.m_iFrames && i < 40; ++i)
                {
                    const std::uintptr_t address = first.m_aFrames[i];
                    out += "  " + Symbolize(i == 0 ? address : address - 1, true) + "\n";
                }
                // Inclusive: in how many samples each function was on the stack.
                std::unordered_map<std::string, int> inclusive;
                std::unordered_map<std::string, int> leaf;
                for (const Sample& sample : _Samples)
                {
                    std::set<std::string> seen;
                    for (int i = 0; i < sample.m_iFrames; ++i)
                    {
                        const std::string& name = symbols.Function(sample.m_aFrames[i]);
                        if (seen.insert(name).second)
                        {
                            inclusive[name]++;
                        }
                    }
                    if (sample.m_iFrames > 0)
                    {
                        leaf[symbols.Function(sample.m_aFrames[0] + 1)]++;
                    }
                }
                auto top = [&](const char* _szTitle, const std::unordered_map<std::string, int>& _Counts, std::size_t _uiMax)
                {
                    std::vector<std::pair<int, std::string>> rows;
                    for (const auto& [name, icount] : _Counts)
                    {
                        rows.emplace_back(icount, name);
                    }
                    std::sort(rows.rbegin(), rows.rend());
                    out += _szTitle;
                    for (std::size_t i = 0; i < rows.size() && i < _uiMax; ++i)
                    {
                        out += Fmt("  %4d  ", rows[i].first) + rows[i].second + "\n";
                    }
                };
                if (_Samples.size() > 1)
                {
                    top("where the samples were (innermost function):\n", leaf, 12);
                    top("on the stack in most samples:\n", inclusive, 30);
                }
            }
            return out + "\n";
        }

        void Run()
        {
            State& s = S();
            SetThreadName("stall watchdog");
            std::vector<Sample> samples;
            std::uint64_t uistallPass = 0;
            std::int64_t istallBegin = 0;
            std::int64_t inextSample = 0;
            std::int64_t inextInterim = 0;
            std::int64_t inextMemory = 0;
            std::int64_t inextMemoryLog = NowNs() + 300'000'000'000LL;
            std::uint64_t uframesLogged = 0;
            std::uint64_t ufailedLogged = 0;

            auto finish = [&](bool _bEnded, std::int64_t _iEnd)
            {
                std::vector<std::pair<std::int64_t, std::string>> traces;
                {
                    std::lock_guard<std::mutex> lock(s.m_TraceMutex);
                    traces = s.m_LuaTraces;
                    if (_bEnded)
                    {
                        s.m_LuaTraces.clear();
                    }
                }
                const std::string text = Describe(samples, istallBegin, _iEnd, _bEnded, traces);
                AppendLog(text);
                if (_bEnded)
                {
                    std::printf("[perf] stall: UI thread busy %.0f ms; %s\n", static_cast<double>(_iEnd - istallBegin) / 1e6,
                        samples.empty() ? "" : ZonePath(samples.front()).c_str());
                    std::fflush(stdout);
                    s.m_iStalls++;
                    std::lock_guard<std::mutex> lock(s.m_ReportMutex);
                    s.m_LastReport = text;
                }
            };

            while (!s.m_bStop.load())
            {
                {
                    std::unique_lock<std::mutex> lock(s.m_WakeMutex);
                    s.m_Wake.wait_for(lock, std::chrono::milliseconds(10), [&] { return s.m_bStop.load(); });
                }
                const std::int64_t inow = NowNs();

                if (inow >= inextMemory)
                {
                    inextMemory = inow + 1'000'000'000LL;
                    const double fprivate = ProcessPrivateMb();
                    Counter("memory: private MB", fprivate);
                    Counter("memory: Lua MB", s.m_fLuaKb.load() / 1024.0);
                    if (inow >= inextMemoryLog)
                    {
                        inextMemoryLog = inow + 300'000'000'000LL;
                        // The frames since the last line.
                        const std::uint64_t uframes = s.m_uFrames.load();
                        const std::uint64_t ufailed = s.m_uFailedFrames.load();
                        const std::int64_t ilast = s.m_iLastFrame.load();
                        const std::string last =
                            ilast == 0 ? std::string("none yet")
                                       : Fmt("the last %.0f s ago", static_cast<double>(inow - ilast) / 1e9);
                        AppendLog(Fmt("-- memory at %s: private %.0f MB, Lua %.1f MB; frames %llu (%llu failed), %s\n",
                            WallClock().c_str(), fprivate, s.m_fLuaKb.load() / 1024.0,
                            static_cast<unsigned long long>(uframes - uframesLogged),
                            static_cast<unsigned long long>(ufailed - ufailedLogged), last.c_str()));
                        uframesLogged = uframes;
                        ufailedLogged = ufailed;
                    }
                }

                const int ithreshold = s.m_iThresholdMs.load();
                const std::int64_t ibusy = s.m_iBusySince.load(std::memory_order_acquire);
                const std::uint64_t uipass = s.m_uiPass.load(std::memory_order_acquire);

                if (uistallPass != 0 && (ibusy == 0 || uipass != uistallPass))
                {
                    // The stalled pass ended.
                    std::int64_t iend = inow;
                    if (s.m_uiLastPass.load() == uistallPass)
                    {
                        iend = s.m_iLastPassEnd.load();
                    }
                    s.m_bLuaWanted.store(false);
                    finish(true, iend);
                    samples.clear();
                    uistallPass = 0;
                }
                if (ithreshold <= 0 || ibusy == 0)
                {
                    continue;
                }
                if (uistallPass == 0 && inow - ibusy >= static_cast<std::int64_t>(ithreshold) * 1'000'000)
                {
                    uistallPass = uipass;
                    istallBegin = ibusy;
                    inextSample = inow;
                    inextInterim = inow + 2'000'000'000LL;
                    std::lock_guard<std::mutex> lock(s.m_TraceMutex);
                    s.m_LuaTraces.clear();
                }
                if (uistallPass == 0)
                {
                    continue;
                }
                if (inow >= inextSample && samples.size() < 4000)
                {
                    inextSample = inow + kSampleEveryMs * 1'000'000LL;
                    Sample sample;
                    if (TakeSample(sample))
                    {
                        samples.push_back(sample);
                    }
                    s.m_bLuaWanted.store(true);
                    if (const LuaTraceRequest pfn = s.m_pfnLuaRequest.load())
                    {
                        pfn();
                    }
                }
                if (inow >= inextInterim)
                {
                    inextInterim = inow + 10'000'000'000LL;
                    finish(false, inow);
                }
            }
        }

    } // namespace

    void StartWatchdog(const WatchdogOptions& _Options)
    {
        State& s = S();
        if (s.m_Thread.joinable())
        {
            return;
        }
        s.m_iThresholdMs.store(_Options.m_iThresholdMs);
        s.m_LogPath = _Options.m_LogPath;
        s.m_pActivity = ThreadActivity();
#if defined(_WIN32)
        DuplicateHandle(GetCurrentProcess(), GetCurrentThread(), GetCurrentProcess(), &s.m_hThread,
            THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, FALSE, 0);
#endif
        s.m_bStop.store(false);
        AppendLog(Fmt("\n-- GitGud started at %s; reporting UI stalls over %d ms\n", WallClock().c_str(), _Options.m_iThresholdMs));
        s.m_Thread = std::thread(Run);
    }

    void StopWatchdog()
    {
        State& s = S();
        if (!s.m_Thread.joinable())
        {
            return;
        }
        s.m_bStop.store(true);
        s.m_Wake.notify_all();
        s.m_Thread.join();
#if defined(_WIN32)
        if (s.m_hThread)
        {
            CloseHandle(s.m_hThread);
            s.m_hThread = nullptr;
        }
#endif
    }

    void SetStallThreshold(int _iMs)
    {
        S().m_iThresholdMs.store(std::max(0, _iMs));
    }

    int StallThreshold()
    {
        return S().m_iThresholdMs.load();
    }

    void UiBusy()
    {
        State& s = S();
        s.m_uiPass.fetch_add(1, std::memory_order_acq_rel);
        s.m_iBusySince.store(NowNs(), std::memory_order_release);
    }

    void UiIdle()
    {
        State& s = S();
        const std::int64_t ibegin = s.m_iBusySince.load(std::memory_order_relaxed);
        if (ibegin == 0)
        {
            return;
        }
        s.m_iLastPassBegin.store(ibegin);
        s.m_iLastPassEnd.store(NowNs());
        s.m_uiLastPass.store(s.m_uiPass.load());
        s.m_iBusySince.store(0, std::memory_order_release);
    }

    void SetLuaMemoryKb(double _fKb)
    {
        S().m_fLuaKb.store(_fKb, std::memory_order_relaxed);
    }

    void CountFrame(bool _bFailed)
    {
        State& s = S();
        s.m_uFrames.fetch_add(1, std::memory_order_relaxed);
        if (_bFailed)
        {
            s.m_uFailedFrames.fetch_add(1, std::memory_order_relaxed);
        }
        s.m_iLastFrame.store(NowNs(), std::memory_order_relaxed);
    }

    bool LuaTraceWanted()
    {
        return S().m_bLuaWanted.load(std::memory_order_relaxed);
    }

    void DeliverLuaTrace(const std::string& _Trace)
    {
        State& s = S();
        s.m_bLuaWanted.store(false);
        std::lock_guard<std::mutex> lock(s.m_TraceMutex);
        if (s.m_LuaTraces.size() < 2000)
        {
            s.m_LuaTraces.emplace_back(NowNs(), _Trace);
        }
    }

    void SetLuaTraceRequest(LuaTraceRequest _pfnRequest)
    {
        S().m_pfnLuaRequest.store(_pfnRequest);
    }

    int StallCount()
    {
        return S().m_iStalls.load();
    }

    std::string LastStallReport()
    {
        State& s = S();
        std::lock_guard<std::mutex> lock(s.m_ReportMutex);
        return s.m_LastReport;
    }

    double ProcessPrivateMb()
    {
#if defined(_WIN32)
        PROCESS_MEMORY_COUNTERS_EX counters{};
        if (GetProcessMemoryInfo(GetCurrentProcess(), reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&counters), sizeof(counters)))
        {
            return static_cast<double>(counters.PrivateUsage) / (1024.0 * 1024.0);
        }
        return 0.0;
#elif defined(__APPLE__)
        task_vm_info_data_t info{};
        mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
        if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count) == KERN_SUCCESS)
        {
            return static_cast<double>(info.phys_footprint) / (1024.0 * 1024.0);
        }
        return 0.0;
#else
        FILE* pfile = std::fopen("/proc/self/statm", "r");
        if (!pfile)
        {
            return 0.0;
        }
        long lsize = 0, lresident = 0;
        const int iread = std::fscanf(pfile, "%ld %ld", &lsize, &lresident);
        std::fclose(pfile);
        return iread == 2 ? static_cast<double>(lresident) * 4096.0 / (1024.0 * 1024.0) : 0.0;
#endif
    }

} // namespace gitgud::prof
