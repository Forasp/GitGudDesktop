#include "agent/ClaudeTranscripts.h"

#include "app/Profiler.h"

#include "agent/ChatImages.h"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstdlib>
#include <deque>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <map>
#include <mutex>
#include <optional>
#include <random>
#include <string>
#include <vector>

namespace gitgud::agent
{

    namespace fs = std::filesystem;
    using app::Json;

    namespace
    {

        // A session's title is near its start: this much is read for it.
        constexpr std::size_t kHeadBytes = 64u * 1024u;
        constexpr std::size_t kTitleChars = 80;

        std::string EnvString(const char* _szName)
        {
            const char* szvalue = std::getenv(_szName);
            return szvalue ? szvalue : "";
        }

        fs::path ProjectDir(const std::string& _WorkingDir)
        {
            return fs::u8path(ClaudeTranscripts::ConfigDir()) / "projects" /
                   fs::u8path(ClaudeTranscripts::ProjectFolderName(_WorkingDir));
        }

        // Session ids are UUIDs: anything else could reach outside the folder.
        bool ValidId(const std::string& _Id)
        {
            return !_Id.empty() && _Id.size() <= 64 &&
                   std::all_of(_Id.begin(), _Id.end(),
                       [](unsigned char _C) { return std::isalnum(_C) || _C == '-' || _C == '_'; });
        }

        // A message's text parts joined; tool results and images left out.
        std::string TextOf(const Json& _Content)
        {
            if (_Content.IsString())
            {
                return _Content.AsString();
            }
            std::string text;
            for (const Json& item : _Content.IsArray() ? _Content.Items() : std::vector<Json>())
            {
                if (item["type"].AsString() == "text")
                {
                    if (!text.empty())
                    {
                        text += "\n";
                    }
                    text += item["text"].AsString();
                }
            }
            return text;
        }

        // Lines Claude Code adds around slash commands, not typed by you.
        bool IsCommandEcho(const std::string& _Text)
        {
            const std::size_t nstart = _Text.find_first_not_of(" \t\r\n");
            if (nstart == std::string::npos)
            {
                return true;
            }
            return _Text.compare(nstart, 9, "<command-") == 0 ||
                   _Text.compare(nstart, 15, "<local-command-") == 0 ||
                   _Text.compare(nstart, 7, "Caveat:") == 0;
        }

        // What's between <_Tag> and </_Tag> in _Text ("" without the tag).
        std::string TagText(const std::string& _Text, const std::string& _Tag)
        {
            const std::string open = "<" + _Tag + ">";
            const std::size_t nopen = _Text.find(open);
            if (nopen == std::string::npos)
            {
                return {};
            }
            const std::size_t nfrom = nopen + open.size();
            const std::size_t nclose = _Text.find("</" + _Tag + ">", nfrom);
            return _Text.substr(nfrom, nclose == std::string::npos ? std::string::npos : nclose - nfrom);
        }

        // A slash command as it was typed ("/compact keep it short"), from
        // the line Claude Code writes for it; "" for any other text.
        std::string TypedCommand(const std::string& _Text)
        {
            const std::size_t nstart = _Text.find_first_not_of(" \t\r\n");
            if (nstart == std::string::npos || _Text.compare(nstart, 9, "<command-") != 0)
            {
                return {};
            }
            std::string typed = TagText(_Text, "command-name");
            if (typed.empty())
            {
                return {};
            }
            if (typed[0] != '/')
            {
                typed.insert(0, "/");
            }
            const std::string args = TagText(_Text, "command-args");
            if (args.find_first_not_of(" \t\r\n") != std::string::npos)
            {
                typed += " " + args;
            }
            return typed;
        }

        // A command's output as Claude Code saves it (a local_command line):
        // the text without its tags, "" when there's none.
        std::string CommandOutput(const std::string& _Text)
        {
            std::string out = TagText(_Text, "local-command-stdout");
            if (out.empty())
            {
                out = TagText(_Text, "local-command-stderr");
            }
            const std::size_t nend = out.find_last_not_of(" \t\r\n");
            return nend == std::string::npos ? std::string() : out.substr(0, nend + 1);
        }

        // Blocks Claude Code, its hooks or another app put in a user message,
        // not typed by you (a conversation was titled
        // "<system-reminder>").
        constexpr const char* kInjectedTags[] = {"system-reminder", "task-notification",
            "user-prompt-submit-hook", "local-command-caveat", "local-command-stdout",
            "local-command-stderr", "command-name", "command-message", "command-args", "bash-input",
            "bash-stdout", "bash-stderr", "voice-context", "pasted_content"};

        // _Text without the injected blocks it starts with: "" when that's
        // all it is (or a block is never closed).
        std::string WithoutInjected(const std::string& _Text)
        {
            std::size_t nat = 0;
            for (;;)
            {
                nat = _Text.find_first_not_of(" \t\r\n", nat);
                if (nat == std::string::npos)
                {
                    return {};
                }
                if (_Text[nat] != '<')
                {
                    return _Text.substr(nat);
                }
                bool bskipped = false;
                for (const char* sztag : kInjectedTags)
                {
                    const std::string tag = sztag;
                    const std::size_t nafter = nat + 1 + tag.size();
                    if (_Text.compare(nat + 1, tag.size(), tag) != 0 || nafter >= _Text.size() ||
                        (_Text[nafter] != '>' && !std::isspace(static_cast<unsigned char>(_Text[nafter]))))
                    {
                        continue;
                    }
                    const std::string close = "</" + tag + ">";
                    const std::size_t nclose = _Text.find(close, nafter);
                    if (nclose == std::string::npos)
                    {
                        return {};
                    }
                    nat = nclose + close.size();
                    bskipped = true;
                    break;
                }
                if (!bskipped)
                {
                    return _Text.substr(nat);
                }
            }
        }

        // Seconds since 1970 for a transcript line's UTC time
        // ("2026-10-19T18:17:43.862Z"), 0 when it isn't one.
        int64_t ParseUtc(const std::string& _Text)
        {
            // Digit positions in "YYYY-MM-DDTHH:MM:SS".
            if (_Text.size() < 19 || _Text[4] != '-' || _Text[7] != '-' || _Text[10] != 'T' ||
                _Text[13] != ':' || _Text[16] != ':')
            {
                return 0;
            }
            auto number = [&](std::size_t _nFrom, std::size_t _nCount) -> int64_t
            {
                int64_t ivalue = 0;
                for (std::size_t i = _nFrom; i < _nFrom + _nCount; ++i)
                {
                    if (!std::isdigit(static_cast<unsigned char>(_Text[i])))
                    {
                        return -1;
                    }
                    ivalue = ivalue * 10 + (_Text[i] - '0');
                }
                return ivalue;
            };
            int64_t iyear = number(0, 4);
            const int64_t imonth = number(5, 2);
            const int64_t iday = number(8, 2);
            const int64_t ihour = number(11, 2);
            const int64_t iminute = number(14, 2);
            const int64_t isecond = number(17, 2);
            if (iyear < 1970 || imonth < 1 || imonth > 12 || iday < 1 || ihour < 0 || iminute < 0 ||
                isecond < 0)
            {
                return 0;
            }
            // Days since 1970 from the civil date (March-based years).
            iyear -= imonth <= 2 ? 1 : 0;
            const int64_t iera = iyear / 400;
            const int64_t iyearOfEra = iyear - iera * 400;
            const int64_t idayOfYear = (153 * (imonth + (imonth > 2 ? -3 : 9)) + 2) / 5 + iday - 1;
            const int64_t idayOfEra = iyearOfEra * 365 + iyearOfEra / 4 - iyearOfEra / 100 + idayOfYear;
            const int64_t idays = iera * 146097 + idayOfEra - 719468;
            return idays * 86400 + ihour * 3600 + iminute * 60 + isecond;
        }

        // A transcript line as JSON, or nothing.
        std::optional<Json> ParseLine(const std::string& _Line)
        {
            if (_Line.find_first_not_of(" \t\r") == std::string::npos)
            {
                return std::nullopt;
            }
            std::optional<Json> parsed = Json::Parse(_Line);
            if (!parsed || !parsed->IsObject())
            {
                return std::nullopt;
            }
            return parsed;
        }

        // Whether a line is the main conversation's (not a sub-agent's, not meta,
        // not compaction's summary, which is for the model).
        bool IsMain(const Json& _Line)
        {
            return !_Line["isSidechain"].AsBool() && !_Line["isMeta"].AsBool() &&
                   !_Line["isCompactSummary"].AsBool();
        }

        // A line of the main conversation, or nothing.
        std::optional<Json> MainLine(const std::string& _Line)
        {
            std::optional<Json> parsed = ParseLine(_Line);
            if (!parsed || !IsMain(*parsed))
            {
                return std::nullopt;
            }
            return parsed;
        }

        // The entry before a line on its branch: its parent, or across a
        // compaction, the entry the summary stands after.
        std::string ParentOf(const Json& _Line)
        {
            const std::string& parent = _Line["parentUuid"].AsString();
            return !parent.empty() ? parent : _Line["logicalParentUuid"].AsString();
        }

        // A user line holding only tool results. Claude Code chains a turn's
        // parallel tool calls one after another, but each result names its
        // own call as its parent: off the branch, yet part of it.
        bool IsToolResults(const Json& _Line)
        {
            const Json& content = _Line["message"]["content"];
            if (_Line["type"].AsString() != "user" || !content.IsArray() || content.Size() == 0)
            {
                return false;
            }
            for (const Json& item : content.Items())
            {
                if (item["type"].AsString() != "tool_result")
                {
                    return false;
                }
            }
            return true;
        }

        int64_t WrittenAt(const fs::path& _Path)
        {
            std::error_code ec;
            const fs::file_time_type written = fs::last_write_time(_Path, ec);
            if (ec)
            {
                return 0;
            }
            // C++17 has no clock_cast: carry the age over to the system clock.
            const auto system = std::chrono::system_clock::now() +
                                std::chrono::duration_cast<std::chrono::system_clock::duration>(
                                    written - fs::file_time_type::clock::now());
            return std::chrono::duration_cast<std::chrono::seconds>(system.time_since_epoch())
                .count();
        }

        // What a session file says: its title (Claude Code's, else a
        // summary, else the first thing asked) and the working folder its
        // lines name, from its first lines; when its last message was, from
        // its end.
        struct Head
        {
            std::string m_Title;
            std::string m_Asked;
            std::string m_Cwd;
            int64_t m_iActive = 0; // 0 when no message line says
        };

        // The title Claude Code gave a session ("custom-title" lines, the
        // last one counts), or "".
        std::string CustomTitle(const Json& _Line)
        {
            return _Line["type"].AsString() == "custom-title"
                       ? ClaudeTranscripts::Title(_Line["customTitle"].AsString())
                       : std::string();
        }

        Head ReadHead(const fs::path& _Path)
        {
            GITGUD_PROFILE_FUNCTION();
            // Read a little at a time: the title and the folder are usually
            // in the first lines, and a list reads many files.
            constexpr std::size_t kChunk = 8u * 1024u;
            std::ifstream in(_Path, std::ios::binary);
            std::string head;
            bool bwhole = false;
            Head result;
            std::string summary;
            std::string firstAsk;
            std::string custom;
            std::size_t nstart = 0;
            auto done = [&] { return (!summary.empty() || !firstAsk.empty()) && !result.m_Cwd.empty(); };
            while (!done())
            {
                if (!bwhole && head.size() < kHeadBytes)
                {
                    const std::size_t nhave = head.size();
                    head.resize(std::min(kHeadBytes, nhave + kChunk));
                    in.read(head.data() + nhave, static_cast<std::streamsize>(head.size() - nhave));
                    head.resize(nhave + static_cast<std::size_t>(in.gcount()));
                    bwhole = !in;
                }
                bool bprogress = false;
                while (nstart < head.size() && !done())
                {
                    const std::size_t nend = head.find('\n', nstart);
                    if (nend == std::string::npos && !bwhole)
                    {
                        break; // cut off by the read: wait for more
                    }
                    bprogress = true;
                    const std::string line =
                        head.substr(nstart, (nend == std::string::npos ? head.size() : nend) - nstart);
                    nstart = nend == std::string::npos ? head.size() : nend + 1;
                    if (result.m_Cwd.empty() && line.find("\"cwd\"") != std::string::npos)
                    {
                        if (std::optional<Json> any = Json::Parse(line))
                        {
                            result.m_Cwd = (*any)["cwd"].AsString();
                        }
                    }
                    std::optional<Json> entry = MainLine(line);
                    if (!entry)
                    {
                        continue;
                    }
                    const Json& value = *entry;
                    if (std::string named = CustomTitle(value); !named.empty())
                    {
                        custom = std::move(named);
                    }
                    if (summary.empty() && value["type"].AsString() == "summary" &&
                        !value["summary"].AsString().empty())
                    {
                        summary = ClaudeTranscripts::Title(value["summary"].AsString());
                    }
                    if (firstAsk.empty() && value["type"].AsString() == "user")
                    {
                        // Title skips what was put in front of what you
                        // typed: a message with nothing else doesn't count.
                        const std::string text = TextOf(value["message"]["content"]);
                        if (!IsCommandEcho(text))
                        {
                            firstAsk = ClaudeTranscripts::Title(text);
                        }
                    }
                }
                const bool bmore = !bwhole && head.size() < kHeadBytes;
                if (!bmore && (nstart >= head.size() || !bprogress))
                {
                    break; // all of the head is read
                }
            }
            result.m_Title = !custom.empty() ? custom : !summary.empty() ? summary : firstAsk;
            result.m_Asked = firstAsk;
            return result;
        }

        // What a session file's end says: its newest title from Claude Code
        // and when its last message (asked or answered) was. Opening a
        // conversation adds lines (its last prompt, its title) but no
        // message, so the list's order doesn't move for it.
        void ReadTail(const fs::path& _Path, Head& _Head)
        {
            GITGUD_PROFILE_FUNCTION();
            std::error_code ec;
            const std::uintmax_t usize = fs::file_size(_Path, ec);
            if (ec || usize == 0)
            {
                return;
            }
            // Mostly the last lines are enough; a long tool result at the end
            // can need more.
            for (const std::uintmax_t uwant : {std::uintmax_t(64u * 1024u), std::uintmax_t(1024u * 1024u)})
            {
                const std::uintmax_t uread = std::min(usize, uwant);
                std::ifstream in(_Path, std::ios::binary);
                in.seekg(static_cast<std::streamoff>(usize - uread));
                std::string tail(static_cast<std::size_t>(uread), '\0');
                in.read(tail.data(), static_cast<std::streamsize>(tail.size()));
                tail.resize(static_cast<std::size_t>(in.gcount()));
                // The first line is cut by the read unless it's the file's start.
                std::size_t nstart = uread < usize ? tail.find('\n') : 0;
                std::string custom;
                int64_t iactive = 0;
                while (nstart != std::string::npos && nstart < tail.size())
                {
                    if (tail[nstart] == '\n')
                    {
                        ++nstart;
                        continue;
                    }
                    const std::size_t nend = tail.find('\n', nstart);
                    const std::string line =
                        tail.substr(nstart, (nend == std::string::npos ? tail.size() : nend) - nstart);
                    nstart = nend;
                    // Cheap tests before parsing: most lines are neither.
                    const bool btitle = line.find("\"custom-title\"") != std::string::npos;
                    const bool bmessage = line.find("\"timestamp\"") != std::string::npos;
                    if (!btitle && !bmessage)
                    {
                        continue;
                    }
                    std::optional<Json> entry = MainLine(line);
                    if (!entry)
                    {
                        continue;
                    }
                    const std::string type = (*entry)["type"].AsString();
                    if (std::string named = CustomTitle(*entry); !named.empty())
                    {
                        custom = std::move(named);
                    }
                    else if (type == "user" || type == "assistant")
                    {
                        if (const int64_t iat = ParseUtc((*entry)["timestamp"].AsString()); iat > 0)
                        {
                            iactive = iat;
                        }
                    }
                }
                if (!custom.empty())
                {
                    _Head.m_Title = std::move(custom);
                }
                if (iactive > 0 || uread == usize)
                {
                    _Head.m_iActive = iactive;
                    return;
                }
            }
        }

        // Heads already read, by path, while the file's write time and size
        // stay the same.
        struct CachedHead
        {
            fs::file_time_type m_Written;
            std::uintmax_t m_uSize = 0;
            Head m_Head;
        };

        std::mutex g_HeadsMutex;
        std::map<std::string, CachedHead> g_Heads;

        Head HeadOf(const fs::path& _Path)
        {
            std::error_code ec;
            const fs::file_time_type written = fs::last_write_time(_Path, ec);
            const std::uintmax_t usize = ec ? 0 : fs::file_size(_Path, ec);
            const std::string key = _Path.u8string();
            if (!ec)
            {
                std::lock_guard<std::mutex> lock(g_HeadsMutex);
                const auto it = g_Heads.find(key);
                if (it != g_Heads.end() && it->second.m_Written == written &&
                    it->second.m_uSize == usize)
                {
                    return it->second.m_Head;
                }
            }
            Head head = ReadHead(_Path);
            ReadTail(_Path, head);
            if (!ec)
            {
                std::lock_guard<std::mutex> lock(g_HeadsMutex);
                g_Heads[key] = {written, usize, head};
            }
            return head;
        }

        // A project folder's session files, newest first.
        std::vector<std::pair<int64_t, fs::path>> SessionFiles(const fs::path& _Dir)
        {
            std::vector<std::pair<int64_t, fs::path>> files;
            std::error_code ec;
            for (fs::directory_iterator it(_Dir, ec), end; !ec && it != end; it.increment(ec))
            {
                const fs::path& path = it->path();
                if (path.extension() == ".jsonl" && ValidId(path.stem().u8string()))
                {
                    files.emplace_back(WrittenAt(path), path);
                }
            }
            std::sort(files.begin(), files.end(),
                [](const auto& _A, const auto& _B) { return _A.first > _B.first; });
            return files;
        }

        // The newest titled sessions of a project folder (at most _nMax).
        std::vector<TranscriptSummary> SessionsIn(const fs::path& _Dir, std::size_t _nMax)
        {
            GITGUD_PROFILE_FUNCTION();
            std::vector<TranscriptSummary> sessions;
            for (const auto& [iupdated, path] : SessionFiles(_Dir))
            {
                if (sessions.size() >= _nMax)
                {
                    break;
                }
                Head head = HeadOf(path);
                if (head.m_Title.empty())
                {
                    continue; // nothing was ever asked: not worth listing
                }
                const int64_t iactive = head.m_iActive > 0 ? head.m_iActive : iupdated;
                sessions.push_back({path.stem().u8string(), std::move(head.m_Title),
                    std::move(head.m_Asked), iupdated, iactive, std::move(head.m_Cwd)});
            }
            std::stable_sort(sessions.begin(), sessions.end(),
                [](const TranscriptSummary& _A, const TranscriptSummary& _B)
                { return _A.m_iActive > _B.m_iActive; });
            return sessions;
        }

    } // namespace

    namespace
    {

        bool IsFile(const fs::path& _Path)
        {
            std::error_code ec;
            return fs::is_regular_file(_Path, ec);
        }

        // The .md files directly in a folder, sorted by name.
        std::vector<fs::path> MarkdownIn(const fs::path& _Dir)
        {
            std::vector<fs::path> files;
            std::error_code ec;
            for (fs::directory_iterator it(_Dir, ec), end; !ec && it != end; it.increment(ec))
            {
                if (it->path().extension() == ".md" && IsFile(it->path()))
                {
                    files.push_back(it->path());
                }
            }
            std::sort(files.begin(), files.end());
            return files;
        }

    } // namespace

    std::vector<ContextFile> ClaudeTranscripts::ContextFiles(const std::string& _WorkingDir)
    {
        GITGUD_PROFILE_FUNCTION();
        std::vector<ContextFile> files;
        auto add = [&files](const char* _szKind, const fs::path& _Path)
        {
            // The config folder can also be a parent's .claude: list it once.
            const std::string path = _Path.lexically_normal().u8string();
            for (const ContextFile& file : files)
            {
                if (file.m_Path == path)
                {
                    return;
                }
            }
            files.push_back({_szKind, path});
        };

        const fs::path config = fs::u8path(ConfigDir());
        if (IsFile(config / "CLAUDE.md"))
        {
            add("user", config / "CLAUDE.md");
        }
        for (const fs::path& rule : MarkdownIn(config / "rules"))
        {
            add("userRule", rule);
        }

        if (!_WorkingDir.empty())
        {
            // The folder and its parents up to, not including, the root;
            // outermost first, so the nearest is last.
            std::vector<fs::path> folders;
            std::error_code ec;
            fs::path folder = fs::absolute(fs::u8path(_WorkingDir), ec).lexically_normal();
            while (!folder.empty() && folder.parent_path() != folder)
            {
                folders.push_back(folder);
                folder = folder.parent_path();
            }
            std::reverse(folders.begin(), folders.end());
            for (const fs::path& dir : folders)
            {
                for (const fs::path& path : {dir / "CLAUDE.md", dir / ".claude" / "CLAUDE.md"})
                {
                    if (IsFile(path))
                    {
                        add("project", path);
                    }
                }
                if (IsFile(dir / "CLAUDE.local.md"))
                {
                    add("local", dir / "CLAUDE.local.md");
                }
                for (const fs::path& rule : MarkdownIn(dir / ".claude" / "rules"))
                {
                    add("projectRule", rule);
                }
            }
            for (const fs::path& note : MarkdownIn(ProjectDir(_WorkingDir) / "memory"))
            {
                add("memory", note);
            }
        }

        std::vector<fs::path> settings{config / "settings.json"};
        if (!_WorkingDir.empty())
        {
            const fs::path dir = fs::u8path(_WorkingDir) / ".claude";
            settings.push_back(dir / "settings.json");
            settings.push_back(dir / "settings.local.json");
        }
        for (const fs::path& path : settings)
        {
            if (IsFile(path))
            {
                add("settings", path);
            }
        }
        return files;
    }

    std::string ClaudeTranscripts::ConfigDir()
    {
        const std::string configured = EnvString("CLAUDE_CONFIG_DIR");
        if (!configured.empty())
        {
            return configured;
        }
        std::string home = EnvString("USERPROFILE");
        if (home.empty())
        {
            home = EnvString("HOME");
        }
        return (fs::u8path(home) / ".claude").u8string();
    }

    std::string ClaudeTranscripts::ProjectFolderName(const std::string& _WorkingDir)
    {
        std::string name = _WorkingDir;
        for (char& c : name)
        {
            if (!std::isalnum(static_cast<unsigned char>(c)))
            {
                c = '-';
            }
        }
        return name;
    }

    std::string ClaudeTranscripts::Title(const std::string& _Text)
    {
        const std::string text = WithoutInjected(_Text);
        if (text.empty())
        {
            return {};
        }
        std::string line = text.substr(0, text.find_first_of("\r\n"));
        while (!line.empty() && std::isspace(static_cast<unsigned char>(line.back())))
        {
            line.pop_back();
        }
        if (line.size() > kTitleChars)
        {
            // Cut at a character's start, never inside a UTF-8 sequence.
            std::size_t ncut = kTitleChars;
            while (ncut > 0 && (static_cast<unsigned char>(line[ncut]) & 0xC0) == 0x80)
            {
                --ncut;
            }
            line = line.substr(0, ncut) + "...";
        }
        return line;
    }

    std::vector<TranscriptSummary> ClaudeTranscripts::List(
        const std::string& _WorkingDir, std::size_t _nMax)
    {
        GITGUD_PROFILE_FUNCTION();
        if (_WorkingDir.empty())
        {
            return {};
        }
        return SessionsIn(ProjectDir(_WorkingDir), _nMax);
    }

    std::vector<ProjectSummary> ClaudeTranscripts::Projects(
        std::size_t _nPerProject, std::size_t _nMaxProjects)
    {
        GITGUD_PROFILE_FUNCTION();
        std::vector<ProjectSummary> projects;
        std::error_code ec;
        const fs::path root = fs::u8path(ConfigDir()) / "projects";
        for (fs::directory_iterator it(root, ec), end; !ec && it != end; it.increment(ec))
        {
            std::error_code dirError;
            if (!it->is_directory(dirError))
            {
                continue;
            }
            ProjectSummary project;
            project.m_Folder = it->path().filename().u8string();
            project.m_Sessions = SessionsIn(it->path(), _nPerProject);
            if (project.m_Sessions.empty())
            {
                continue;
            }
            project.m_iUpdated = project.m_Sessions.front().m_iActive;
            for (const TranscriptSummary& session : project.m_Sessions)
            {
                if (!session.m_Cwd.empty())
                {
                    project.m_Cwd = session.m_Cwd;
                    break;
                }
            }
            projects.push_back(std::move(project));
        }
        std::sort(projects.begin(), projects.end(),
            [](const ProjectSummary& _A, const ProjectSummary& _B)
            {
                return _A.m_iUpdated != _B.m_iUpdated ? _A.m_iUpdated > _B.m_iUpdated
                                                      : _A.m_Folder < _B.m_Folder;
            });
        if (projects.size() > _nMaxProjects)
        {
            projects.resize(_nMaxProjects);
        }
        return projects;
    }

    std::string ClaudeTranscripts::Find(const std::string& _WorkingDir, const std::string& _Id)
    {
        GITGUD_PROFILE_FUNCTION();
        if (!ValidId(_Id))
        {
            return {};
        }
        const std::string file = _Id + ".jsonl";
        if (!_WorkingDir.empty())
        {
            const fs::path path = ProjectDir(_WorkingDir) / fs::u8path(file);
            if (IsFile(path))
            {
                return path.u8string();
            }
        }
        std::error_code ec;
        const fs::path root = fs::u8path(ConfigDir()) / "projects";
        for (fs::directory_iterator it(root, ec), end; !ec && it != end; it.increment(ec))
        {
            const fs::path path = it->path() / fs::u8path(file);
            if (IsFile(path))
            {
                return path.u8string();
            }
        }
        return {};
    }

    namespace
    {

        // The conversation entries of one main transcript line, in order.
        void EntriesOf(const Json& _Line, std::vector<TranscriptEntry>& _Out)
        {
            GITGUD_PROFILE_FUNCTION();
            auto add = [&](TranscriptEntry _Entry)
            {
                _Entry.m_Uuid = _Line["uuid"].AsString();
                _Entry.m_ParentUuid = ParentOf(_Line);
                _Out.push_back(std::move(_Entry));
            };
            const std::string type = _Line["type"].AsString();
            const Json& content = _Line["message"]["content"];
            if (type == "system")
            {
                // A command's output, and where the conversation was compacted.
                const std::string subtype = _Line["subtype"].AsString();
                const std::string output =
                    subtype == "local_command" ? CommandOutput(_Line["content"].AsString()) : "";
                if (!output.empty())
                {
                    add({"assistant", output, "", "", Json(), false});
                }
                else if (subtype == "compact_boundary")
                {
                    const Json& metadata = _Line["compactMetadata"];
                    add({"compacted", metadata["trigger"].AsString(), "", "", metadata, false});
                }
                return;
            }
            if (type == "user")
            {
                if (content.IsString())
                {
                    const std::string typed = TypedCommand(content.AsString());
                    if (!typed.empty())
                    {
                        add({"user", typed, "", "", Json(), false});
                    }
                    else if (!IsCommandEcho(content.AsString()))
                    {
                        add({"user", content.AsString(), "", "", Json(), false});
                    }
                    return;
                }
                // Pasted images go with the message's text (a message of
                // their own when it has none).
                std::vector<std::string> images = ChatImagesIn(content);
                for (const Json& item : content.IsArray() ? content.Items() : std::vector<Json>())
                {
                    const std::string kind = item["type"].AsString();
                    if (kind == "text" && !IsCommandEcho(item["text"].AsString()))
                    {
                        add({"user", item["text"].AsString(), "", "", Json(), false, std::move(images)});
                        images.clear();
                    }
                    else if (kind == "tool_result")
                    {
                        add({"toolResult", TextOf(item["content"]), item["tool_use_id"].AsString(),
                            "", Json(), item["is_error"].AsBool(), ChatImagesIn(item["content"])});
                    }
                }
                if (!images.empty())
                {
                    add({"user", "", "", "", Json(), false, std::move(images)});
                }
            }
            else if (type == "assistant")
            {
                for (const Json& item : content.IsArray() ? content.Items() : std::vector<Json>())
                {
                    const std::string kind = item["type"].AsString();
                    if (kind == "text" && !item["text"].AsString().empty())
                    {
                        add({"assistant", item["text"].AsString(), "", "", Json(), false});
                    }
                    else if (kind == "tool_use")
                    {
                        add({"tool", "", item["id"].AsString(), item["name"].AsString(),
                            item["input"], false});
                    }
                }
            }
        }

    } // namespace

    namespace
    {
        // The last reads, by file and count: a transcript that hasn't
        // changed (its size and time) reads the same. Opening a
        // conversation, the recap and rewind read the same files again and
        // again; a long one took hundreds of milliseconds each time.
        struct ReadCache
        {
            struct Entry
            {
                std::string m_File;
                std::size_t m_nMax = 0;
                std::uintmax_t m_uiSize = 0;
                fs::file_time_type m_Time;
                std::uint64_t m_uiUsed = 0;
                std::vector<TranscriptEntry> m_Entries;
            };
            static constexpr std::size_t kMax = 24;
            std::mutex m_Mutex;
            std::vector<Entry> m_Entries;
            std::uint64_t m_uiClock = 0;
        };

        ReadCache& TheReadCache()
        {
            static ReadCache s_Cache;
            return s_Cache;
        }
    } // namespace

    std::vector<TranscriptEntry> ClaudeTranscripts::Read(
        const std::string& _WorkingDir, const std::string& _Id, std::size_t _nMax)
    {
        GITGUD_PROFILE_FUNCTION();
        if (_nMax == 0)
        {
            return {};
        }
        const std::string file = Find(_WorkingDir, _Id);
        if (file.empty())
        {
            return {};
        }
        std::error_code ec;
        const std::uintmax_t uisize = fs::file_size(fs::u8path(file), ec);
        const fs::file_time_type time = ec ? fs::file_time_type{} : fs::last_write_time(fs::u8path(file), ec);
        const bool bcacheable = !ec;
        ReadCache& cache = TheReadCache();
        if (bcacheable)
        {
            std::lock_guard<std::mutex> lock(cache.m_Mutex);
            for (ReadCache::Entry& entry : cache.m_Entries)
            {
                if (entry.m_File == file && entry.m_nMax == _nMax && entry.m_uiSize == uisize && entry.m_Time == time)
                {
                    entry.m_uiUsed = ++cache.m_uiClock;
                    return entry.m_Entries;
                }
            }
        }
        std::vector<TranscriptEntry> entries = ReadFile(file, _nMax);
        if (bcacheable)
        {
            std::lock_guard<std::mutex> lock(cache.m_Mutex);
            auto old = std::find_if(cache.m_Entries.begin(), cache.m_Entries.end(),
                [&](const ReadCache::Entry& _Entry) { return _Entry.m_File == file && _Entry.m_nMax == _nMax; });
            if (old == cache.m_Entries.end() && cache.m_Entries.size() >= ReadCache::kMax)
            {
                old = std::min_element(cache.m_Entries.begin(), cache.m_Entries.end(),
                    [](const ReadCache::Entry& _A, const ReadCache::Entry& _B) { return _A.m_uiUsed < _B.m_uiUsed; });
            }
            if (old == cache.m_Entries.end())
            {
                cache.m_Entries.emplace_back();
                old = std::prev(cache.m_Entries.end());
            }
            old->m_File = file;
            old->m_nMax = _nMax;
            old->m_uiSize = uisize;
            old->m_Time = time;
            old->m_uiUsed = ++cache.m_uiClock;
            old->m_Entries = entries;
        }
        return entries;
    }

    std::vector<TranscriptEntry> ClaudeTranscripts::ReadFile(const std::string& file, std::size_t _nMax)
    {
        GITGUD_PROFILE_FUNCTION();
        std::ifstream in(fs::u8path(file), std::ios::binary);
        if (!in)
        {
            return {};
        }
        // Only the latest entries are wanted and a long session's file runs
        // to tens of megabytes: read it from its end, a block at a time, and
        // stop once there are enough (opening a long
        // conversation hitched).
        constexpr std::streamoff kBlock = 256 * 1024;
        in.seekg(0, std::ios::end);
        std::streamoff pos = in.tellg();
        std::string tail; // the start of the line cut by the last block read

        // Lines are read last first, and only the branch the last one is on
        // is kept (Claude Code resumes that one): `wanted` is the entry it
        // goes on at, going back. Tool results that name a call on it are
        // held until that call is reached (IsToolResults). Each line's
        // entries are kept with its place from the end, so held ones go
        // back where they were.
        struct LineEntries
        {
            std::size_t m_nFromEnd = 0;
            std::vector<TranscriptEntry> m_Entries;
        };
        std::vector<LineEntries> kept;
        std::map<std::string, std::vector<LineEntries>> held; // by the call's uuid
        std::string wanted;
        bool bfollowing = true; // false once the branch's first entry is passed
        std::size_t nlines = 0;
        std::size_t ncount = 0; // entries kept
        auto keep = [&](LineEntries _Line)
        {
            ncount += _Line.m_Entries.size();
            kept.push_back(std::move(_Line));
        };
        auto takeLine = [&](const std::string& _Line)
        {
            const std::size_t nfromEnd = nlines++;
            std::optional<Json> parsed = ParseLine(_Line);
            if (!parsed)
            {
                return;
            }
            LineEntries line{nfromEnd, {}};
            if (IsMain(*parsed))
            {
                EntriesOf(*parsed, line.m_Entries);
            }
            const std::string& uuid = (*parsed)["uuid"].AsString();
            if (!bfollowing || uuid.empty() || (*parsed)["isSidechain"].AsBool())
            {
                keep(std::move(line));
                return;
            }
            if (!wanted.empty() && uuid != wanted)
            {
                if (IsToolResults(*parsed))
                {
                    held[ParentOf(*parsed)].push_back(std::move(line));
                }
                return; // another branch: one left behind by a rewind
            }
            keep(std::move(line));
            const auto it = held.find(uuid);
            if (it != held.end())
            {
                for (LineEntries& results : it->second)
                {
                    keep(std::move(results));
                }
                held.erase(it);
            }
            wanted = ParentOf(*parsed);
            bfollowing = !wanted.empty();
        };
        while (pos > 0 && ncount < _nMax)
        {
            const std::streamoff nread = std::min(kBlock, pos);
            pos -= nread;
            std::string block(static_cast<std::size_t>(nread), '\0');
            in.seekg(pos);
            in.read(block.data(), nread);
            block.resize(static_cast<std::size_t>(in.gcount()));
            block += tail;
            // Every line but the first is whole; the first may go on in the
            // block before.
            std::size_t nend = block.size();
            while (ncount < _nMax)
            {
                const std::size_t nbreak =
                    nend == 0 ? std::string::npos : block.rfind('\n', nend - 1);
                if (nbreak == std::string::npos)
                {
                    break;
                }
                takeLine(block.substr(nbreak + 1, nend - nbreak - 1));
                nend = nbreak;
            }
            tail = block.substr(0, nend);
        }
        if (pos == 0 && ncount < _nMax && !tail.empty())
        {
            takeLine(tail);
        }
        // In the file's order: first the line furthest from its end.
        std::sort(kept.begin(), kept.end(),
            [](const LineEntries& _A, const LineEntries& _B) { return _A.m_nFromEnd > _B.m_nFromEnd; });
        std::deque<TranscriptEntry> entries;
        for (LineEntries& line : kept)
        {
            std::move(line.m_Entries.begin(), line.m_Entries.end(), std::back_inserter(entries));
        }
        while (entries.size() > _nMax)
        {
            entries.pop_front();
        }
        return {entries.begin(), entries.end()};
    }

    std::string ClaudeTranscripts::NewId()
    {
        std::random_device device;
        std::mt19937_64 random((static_cast<uint64_t>(device()) << 32) ^ device() ^
                               static_cast<uint64_t>(
                                   std::chrono::steady_clock::now().time_since_epoch().count()));
        std::uniform_int_distribution<int> digit(0, 15);
        static const char* kszDigits = "0123456789abcdef";
        std::string id;
        for (int i = 0; i < 36; ++i)
        {
            if (i == 8 || i == 13 || i == 18 || i == 23)
            {
                id += '-';
            }
            else if (i == 14)
            {
                id += '4'; // version 4: random
            }
            else if (i == 19)
            {
                id += kszDigits[8 + digit(random) % 4]; // the variant
            }
            else
            {
                id += kszDigits[digit(random)];
            }
        }
        return id;
    }

    std::string ClaudeTranscripts::Fork(const std::string& _WorkingDir, const std::string& _Id,
        const std::string& _UpTo, const std::string& _ToDir)
    {
        GITGUD_PROFILE_FUNCTION();
        const std::string file = Find(_WorkingDir, _Id);
        if (file.empty() || _ToDir.empty())
        {
            return {};
        }
        std::ifstream in(fs::u8path(file), std::ios::binary);
        std::vector<Json> lines; // those with a uuid, in order
        std::map<std::string, std::size_t> byUuid;
        std::string line;
        while (std::getline(in, line))
        {
            std::optional<Json> parsed = ParseLine(line);
            if (parsed && !(*parsed)["uuid"].AsString().empty() && !(*parsed)["isSidechain"].AsBool())
            {
                byUuid[(*parsed)["uuid"].AsString()] = lines.size();
                lines.push_back(std::move(*parsed));
            }
        }
        if (lines.empty())
        {
            return {};
        }
        // The branch, from the entry asked for (else the last) back to its first.
        const auto last = _UpTo.empty() ? byUuid.find(lines.back()["uuid"].AsString())
                                        : byUuid.find(_UpTo);
        if (last == byUuid.end())
        {
            return {};
        }
        const std::size_t nlast = last->second;
        std::vector<bool> bkeep(lines.size(), false);
        for (auto it = last; it != byUuid.end() && !bkeep[it->second];
             it = byUuid.find(ParentOf(lines[it->second])))
        {
            bkeep[it->second] = true;
        }
        // And the results of its parallel tool calls (IsToolResults).
        for (std::size_t i = 0; i < nlast; ++i)
        {
            const auto parent = byUuid.find(ParentOf(lines[i]));
            if (!bkeep[i] && IsToolResults(lines[i]) && parent != byUuid.end() && bkeep[parent->second])
            {
                bkeep[i] = true;
            }
        }

        const std::string id = NewId();
        const fs::path dir = ProjectDir(_ToDir);
        std::error_code ec;
        fs::create_directories(dir, ec);
        const fs::path path = dir / fs::u8path(id + ".jsonl");
        std::ofstream out(path, std::ios::binary);
        if (!out)
        {
            return {};
        }
        for (std::size_t i = 0; i <= nlast; ++i)
        {
            if (!bkeep[i])
            {
                continue;
            }
            Json& copy = lines[i];
            copy.Set("sessionId", id);
            if (copy.Has("cwd"))
            {
                copy.Set("cwd", _ToDir);
            }
            out << copy.Dump() << "\n";
        }
        out.close();
        return out ? id : std::string();
    }

} // namespace gitgud::agent
