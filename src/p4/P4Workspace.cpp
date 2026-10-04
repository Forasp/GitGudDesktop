// -----------------------------------------------------------------------------
// P4Workspace: plumbing, opening/creating workspaces, status, opening files
// ("staging"), submitting, config, the server as the one remote, and getting
// latest. History lives in P4WorkspaceHistory.cpp; branches, labels, merges,
// shelves and workspaces in P4WorkspaceBranches.cpp.
// -----------------------------------------------------------------------------

#include "p4/P4Workspace.h"

#include "git/LibGit2Internal.h"
#include "p4/P4Internal.h"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <fstream>
#include <set>
#include <sstream>

#if !defined(_WIN32)
#include <unistd.h>
#endif

namespace gitgud::p4
{

    using git::GitError;

    namespace
    {

        namespace fs = std::filesystem;

        std::mutex g_DefaultMutex;
        PasswordProvider g_DefaultPasswords;

        const char* const g_szConfigFile = ".p4config";

        void SetEnv(const char* _szName, const char* _szValue)
        {
#if defined(_WIN32)
            _putenv_s(_szName, _szValue);
#else
            setenv(_szName, _szValue, 1);
#endif
        }

        // P4IGNORE names the ignore file p4 reconcile/status honor. Commands
        // inherit our environment, so set it once when the user hasn't.
        void EnsureIgnoreSetting()
        {
            static std::once_flag s_Once;
            std::call_once(s_Once,
                []()
                {
                    if (!std::getenv("P4IGNORE"))
                    {
                        SetEnv("P4IGNORE", ".p4ignore");
                    }
                    // Naming our settings file as P4CONFIG also makes p4
                    // refuse to add it (P4_SYSTEMIGNORE).
                    if (!std::getenv("P4CONFIG"))
                    {
                        SetEnv("P4CONFIG", ".p4config");
                    }
                });
        }

        std::string HostName()
        {
#if defined(_WIN32)
            const char* sz = std::getenv("COMPUTERNAME");
            return sz ? std::string(sz) : std::string("host");
#else
            char szname[256] = {};
            if (gethostname(szname, sizeof(szname) - 1) == 0 && szname[0])
            {
                return szname;
            }
            return "host";
#endif
        }

        // "C:\Work\Proj\" -> "C:/Work/Proj".
        std::string NormalizeRoot(const std::string& _Path)
        {
            std::error_code ec;
            fs::path p = fs::weakly_canonical(fs::u8path(_Path), ec);
            if (ec)
            {
                p = fs::u8path(_Path);
            }
            std::string out = p.u8string();
            std::replace(out.begin(), out.end(), '\\', '/');
            while (out.size() > 3 && out.back() == '/')
            {
                out.pop_back();
            }
            return out;
        }

    } // namespace

    // ---- internal helpers shared by the backend files ---------------------------

    namespace internal
    {

        bool StartsWithNoCase(const std::string& _Text, const std::string& _Prefix)
        {
            if (_Text.size() < _Prefix.size())
            {
                return false;
            }
            for (std::size_t i = 0; i < _Prefix.size(); ++i)
            {
                if (std::tolower(static_cast<unsigned char>(_Text[i])) !=
                    std::tolower(static_cast<unsigned char>(_Prefix[i])))
                {
                    return false;
                }
            }
            return true;
        }

        std::string ToSlashes(std::string _Path)
        {
            std::replace(_Path.begin(), _Path.end(), '\\', '/');
            return _Path;
        }

        std::int64_t ToInt64(const std::string& _Text)
        {
            return std::strtoll(_Text.c_str(), nullptr, 10);
        }

        // Every "<_Prefix><n>" field of a record, in order (View0, View1, ...).
        std::vector<std::string> Indexed(const Record& _Record, const std::string& _Prefix)
        {
            std::vector<std::string> out;
            for (int i = 0;; ++i)
            {
                const auto it = _Record.find(_Prefix + std::to_string(i));
                if (it == _Record.end())
                {
                    break;
                }
                out.push_back(it->second);
            }
            return out;
        }

        // Strip the "code" field and any extraTag metadata p4 adds to `-o`
        // output, so the record can go back with `-i`.
        Record SpecForInput(Record _Spec)
        {
            _Spec.erase("code");
            std::vector<std::string> extra;
            for (int i = 0;; ++i)
            {
                const auto it = _Spec.find("extraTag" + std::to_string(i));
                if (it == _Spec.end())
                {
                    break;
                }
                extra.push_back(it->second);
                _Spec.erase("extraTagType" + std::to_string(i));
                _Spec.erase(it);
            }
            for (const std::string& key : extra)
            {
                _Spec.erase(key);
            }
            return _Spec;
        }

        // "Change 12 created ..." / "... change 12 ..." -> "12".
        std::string NumberAfter(const std::string& _Text, const std::string& _Word)
        {
            std::size_t npos = 0;
            while ((npos = _Text.find(_Word, npos)) != std::string::npos)
            {
                std::size_t nstart = npos + _Word.size();
                while (nstart < _Text.size() && _Text[nstart] == ' ')
                {
                    ++nstart;
                }
                std::size_t nend = nstart;
                while (nend < _Text.size() && std::isdigit(static_cast<unsigned char>(_Text[nend])))
                {
                    ++nend;
                }
                if (nend > nstart)
                {
                    return _Text.substr(nstart, nend - nstart);
                }
                npos = nstart;
            }
            return {};
        }

        git::internal::FileVersion Version(const std::string& _Text, bool _bExists)
        {
            git::internal::FileVersion v;
            v.m_Text = _Text;
            v.m_bExists = _bExists;
            return v;
        }

        // p4 hands text back with the client's line endings in some commands
        // (annotate); compare and diff in LF form.
        std::string ToLf(const std::string& _Text)
        {
            std::string out;
            out.reserve(_Text.size());
            for (std::size_t i = 0; i < _Text.size(); ++i)
            {
                if (_Text[i] == '\r' && i + 1 < _Text.size() && _Text[i + 1] == '\n')
                {
                    continue;
                }
                out.push_back(_Text[i]);
            }
            return out;
        }

        std::vector<std::string> SplitLines(const std::string& _Text)
        {
            std::vector<std::string> out;
            std::size_t nstart = 0;
            while (nstart < _Text.size())
            {
                std::size_t nend = _Text.find('\n', nstart);
                if (nend == std::string::npos)
                {
                    nend = _Text.size();
                }
                std::string line = _Text.substr(nstart, nend - nstart);
                if (!line.empty() && line.back() == '\r')
                {
                    line.pop_back();
                }
                out.push_back(std::move(line));
                nstart = nend + 1;
            }
            return out;
        }

    } // namespace internal

    using namespace internal;

    // ---- config file ---------------------------------------------------------------

    std::map<std::string, std::string> P4Workspace::ReadConfigFile(const std::string& _Root)
    {
        std::map<std::string, std::string> out;
        std::ifstream in(fs::u8path(_Root) / g_szConfigFile);
        std::string line;
        while (std::getline(in, line))
        {
            if (!line.empty() && line.back() == '\r')
            {
                line.pop_back();
            }
            const std::size_t neq = line.find('=');
            if (line.empty() || line[0] == '#' || neq == std::string::npos)
            {
                continue;
            }
            out[line.substr(0, neq)] = line.substr(neq + 1);
        }
        return out;
    }

    void P4Workspace::WriteConfigFile(
        const std::string& _Root, const std::map<std::string, std::string>& _Values)
    {
        std::ofstream out(fs::u8path(_Root) / g_szConfigFile, std::ios::binary | std::ios::trunc);
        if (!out)
        {
            throw GitError(
                "Could not write " + std::string(g_szConfigFile) + " in '" + _Root + "'");
        }
        out << "# Written by GitGud: the Perforce server and workspace for this folder.\n";
        // P4 settings first (the p4 command line reads these too when
        // P4CONFIG=.p4config), then GitGud's own.
        for (const char* szkey : {"P4PORT", "P4USER", "P4CLIENT", "P4CHARSET"})
        {
            const auto it = _Values.find(szkey);
            if (it != _Values.end() && !it->second.empty())
            {
                out << it->first << "=" << it->second << "\n";
            }
        }
        for (const auto& [key, value] : _Values)
        {
            if (key.rfind("P4", 0) != 0 && !value.empty())
            {
                out << key << "=" << value << "\n";
            }
        }
    }

    void P4Workspace::SaveConfig()
    {
        WriteConfigFile(m_Root, m_Config);
    }

    // ---- open / create ---------------------------------------------------------------

    bool P4Workspace::IsWorkspace(const std::string& _Path)
    {
        std::error_code ec;
        if (!fs::exists(fs::u8path(_Path) / g_szConfigFile, ec))
        {
            return false;
        }
        const auto config = ReadConfigFile(_Path);
        const auto it = config.find("P4CLIENT");
        return it != config.end() && !it->second.empty();
    }

    void P4Workspace::SetDefaultPasswordProvider(PasswordProvider _Provider)
    {
        std::lock_guard<std::mutex> lock(g_DefaultMutex);
        g_DefaultPasswords = std::move(_Provider);
    }

    PasswordProvider P4Workspace::FromCredentialProvider(const git::CredentialProvider& _Provider)
    {
        if (!_Provider)
        {
            return nullptr;
        }
        return [_Provider](const std::string& _Port, const std::string& _User, bool _bRejected,
                   std::string& _OutPassword)
        {
            std::string user;
            return _Provider("p4:" + _Port, _User, _bRejected, user, _OutPassword);
        };
    }

    void P4Workspace::SetPasswordProvider(PasswordProvider _Provider)
    {
        m_Passwords = std::move(_Provider);
    }

    std::unique_ptr<P4Workspace> P4Workspace::Open(const std::string& _Path)
    {
        EnsureIgnoreSetting();
        if (!IsWorkspace(_Path))
        {
            throw GitError(
                "'" + _Path + "' is not a Perforce workspace (no .p4config naming P4CLIENT)");
        }
        auto ws = std::make_unique<P4Workspace>();
        ws->m_Root = NormalizeRoot(_Path);
        ws->m_Config = ReadConfigFile(_Path);
        ws->m_Conn.m_Port = ws->m_Config["P4PORT"];
        ws->m_Conn.m_User = ws->m_Config["P4USER"];
        ws->m_Conn.m_Client = ws->m_Config["P4CLIENT"];
        ws->m_Conn.m_Charset = ws->m_Config["P4CHARSET"];
        ws->m_Conn.m_Dir = fs::u8path(ws->m_Root).make_preferred().u8string();
        ws->m_BranchRoot = ws->m_Config["GITGUD_BRANCHROOT"];
        // Reading the client spec needs the server; a workspace still opens
        // offline (status then reports the connection error).
        try
        {
            ws->LoadClient();
        }
        catch (const GitError&)
        {
            ws->m_Stream = ws->m_Config["GITGUD_STREAM"];
        }
        return ws;
    }

    void P4Workspace::LoadClient()
    {
        const CommandResult r = RunOrThrow({"client", "-o", m_Conn.m_Client});
        if (r.m_Stats.empty())
        {
            throw GitError("Workspace '" + m_Conn.m_Client + "' could not be read");
        }
        const Record& spec = r.m_Stats.front();
        if (Field(spec, "Update").empty() && Field(spec, "Access").empty())
        {
            // `client -o` invents a default spec for names that don't exist.
            throw GitError("Workspace '" + m_Conn.m_Client + "' doesn't exist on " + m_Conn.m_Port);
        }
        m_Stream = Field(spec, "Stream");
        m_View.clear();
        for (const std::string& line : Indexed(spec, "View"))
        {
            // "<depot> <client>", either side possibly quoted.
            std::vector<std::string> parts;
            std::string cur;
            bool bquoted = false;
            for (const char c : line)
            {
                if (c == '"')
                {
                    bquoted = !bquoted;
                    continue;
                }
                if (c == ' ' && !bquoted)
                {
                    if (!cur.empty())
                    {
                        parts.push_back(cur);
                        cur.clear();
                    }
                    continue;
                }
                cur.push_back(c);
            }
            if (!cur.empty())
            {
                parts.push_back(cur);
            }
            if (parts.size() == 2)
            {
                m_View.emplace_back(parts[0], parts[1]);
            }
        }
        if (m_Config["GITGUD_STREAM"] != m_Stream)
        {
            m_Config["GITGUD_STREAM"] = m_Stream;
            try
            {
                SaveConfig();
            }
            catch (const GitError&)
            {
                // read-only folder: the value is only a cache
            }
        }
    }

    std::unique_ptr<P4Workspace> P4Workspace::Create(
        const WorkspaceSetup& _Setup, const PasswordProvider& _Passwords)
    {
        EnsureIgnoreSetting();
        if (_Setup.m_Port.empty() || _Setup.m_User.empty() || _Setup.m_Root.empty())
        {
            throw GitError("A Perforce workspace needs a server, a user, and a folder");
        }
        std::error_code ec;
        fs::create_directories(fs::u8path(_Setup.m_Root), ec);
        const std::string root = NormalizeRoot(_Setup.m_Root);

        Connection conn;
        conn.m_Port = _Setup.m_Port;
        conn.m_User = _Setup.m_User;
        conn.m_Charset = _Setup.m_Charset;
        conn.m_Dir = fs::u8path(root).make_preferred().u8string();

        if (!_Setup.m_Password.empty())
        {
            std::string error;
            if (!P4Command::Login(conn, _Setup.m_Password, error))
            {
                throw GitError(error);
            }
        }
        PasswordProvider passwords = _Passwords;
        if (!passwords)
        {
            std::lock_guard<std::mutex> lock(g_DefaultMutex);
            passwords = g_DefaultPasswords;
        }

        // No stream or path: connect to the workspace the server already
        // has for this folder (one made by another client has no .p4config).
        if (_Setup.m_Stream.empty() && _Setup.m_DepotPath.empty())
        {
            std::string found = _Setup.m_Client;
            if (found.empty())
            {
                for (const WorkspaceInfo& w : ListWorkspaces(conn, passwords))
                {
                    const bool bhostOk =
                        w.m_Host.empty() || internal::StartsWithNoCase(w.m_Host, HostName());
                    if (bhostOk && !w.m_Root.empty() &&
                        internal::StartsWithNoCase(NormalizeRoot(w.m_Root), root) &&
                        NormalizeRoot(w.m_Root).size() == root.size())
                    {
                        found = w.m_Name;
                        break;
                    }
                }
            }
            if (found.empty())
            {
                throw GitError(
                    "No workspace of " + _Setup.m_User + " on " + _Setup.m_Port +
                    " uses this folder. Enter the stream (//depot/main) or depot path to map.");
            }
            std::map<std::string, std::string> config;
            config["P4PORT"] = conn.m_Port;
            config["P4USER"] = conn.m_User;
            config["P4CLIENT"] = found;
            config["P4CHARSET"] = conn.m_Charset;
            WriteConfigFile(root, config);
            auto existing = Open(root);
            existing->m_Passwords = _Passwords;
            if (!existing->UsesStreams() && existing->m_BranchRoot.empty())
            {
                // Classic view: its folder's siblings are the branches.
                const std::string depotRoot = existing->GetConfig("p4.depotRoot");
                const std::size_t nslash = depotRoot.rfind('/');
                if (nslash != std::string::npos && nslash > 2)
                {
                    existing->m_BranchRoot = depotRoot.substr(0, nslash);
                    existing->m_Config["GITGUD_BRANCHROOT"] = existing->m_BranchRoot;
                    existing->SaveConfig();
                }
            }
            return existing;
        }

        std::string client = _Setup.m_Client;
        if (client.empty())
        {
            client =
                _Setup.m_User + "-" + HostName() + "-" + fs::u8path(root).filename().u8string();
            std::replace(client.begin(), client.end(), ' ', '-');
        }
        conn.m_Client = client;

        // Brand-new repository: the stream depot and the mainline stream.
        if (!_Setup.m_Stream.empty() && _Setup.m_bCreate)
        {
            const std::string stream = _Setup.m_Stream;
            if (stream.rfind("//", 0) != 0 || stream.find('/', 2) == std::string::npos)
            {
                throw GitError("A stream is named like //depot/main");
            }
            const std::string depot = stream.substr(2, stream.find('/', 2) - 2);
            const CommandResult depots = P4Command::RunOrThrow(conn, {"depots"}, {}, passwords);
            bool bhaveDepot = false;
            for (const Record& d : depots.m_Stats)
            {
                bhaveDepot = bhaveDepot || Field(d, "name") == depot;
            }
            if (!bhaveDepot)
            {
                CommandResult spec = P4Command::RunOrThrow(
                    conn, {"depot", "-o", "-t", "stream", depot}, {}, passwords);
                if (spec.m_Stats.empty())
                {
                    throw GitError("Could not prepare depot '" + depot + "'");
                }
                P4Command::RunOrThrow(
                    conn, {"depot", "-i"}, SpecForInput(spec.m_Stats.front()), passwords);
            }
            const CommandResult existing = P4Command::Run(conn, {"streams", stream}, {}, passwords);
            if (existing.m_Stats.empty())
            {
                CommandResult spec = P4Command::RunOrThrow(
                    conn, {"stream", "-o", "-t", "mainline", stream}, {}, passwords);
                if (spec.m_Stats.empty())
                {
                    throw GitError("Could not prepare stream '" + stream + "'");
                }
                Record in = SpecForInput(spec.m_Stats.front());
                in["Description"] = "Created by GitGud.\n";
                P4Command::RunOrThrow(conn, {"stream", "-i"}, in, passwords);
            }
        }

        // The client spec: allwrite (edit anything, like a Git working tree;
        // GitGud opens files when you stage them) and noclobber (sync never
        // overwrites a file you changed without opening it).
        std::vector<std::string> args = {"client", "-o"};
        if (!_Setup.m_Stream.empty())
        {
            args.emplace_back("-S");
            args.push_back(_Setup.m_Stream);
        }
        args.push_back(client);
        CommandResult tmpl = P4Command::RunOrThrow(conn, args, {}, passwords);
        if (tmpl.m_Stats.empty())
        {
            throw GitError("Could not prepare workspace '" + client + "'");
        }
        if (!Field(tmpl.m_Stats.front(), "Update").empty())
        {
            throw GitError("Workspace '" + client + "' already exists; choose another name");
        }
        Record spec = SpecForInput(tmpl.m_Stats.front());
        spec["Root"] = conn.m_Dir;
        spec["Options"] = "allwrite noclobber nocompress unlocked nomodtime rmdir";
        spec["Description"] = "Created by GitGud.\n";
        spec["LineEnd"] = "local";
        if (_Setup.m_Stream.empty())
        {
            for (auto it = spec.begin(); it != spec.end();)
            {
                it = it->first.rfind("View", 0) == 0 ? spec.erase(it) : std::next(it);
            }
            std::string depotPath = _Setup.m_DepotPath;
            while (!depotPath.empty() && (depotPath.back() == '/' || depotPath.back() == '.'))
            {
                depotPath.pop_back();
            }
            spec["View0"] = "\"" + depotPath + "/...\" \"//" + client + "/...\"";
        }
        P4Command::RunOrThrow(conn, {"client", "-i"}, spec, passwords);

        std::map<std::string, std::string> config;
        config["P4PORT"] = conn.m_Port;
        config["P4USER"] = conn.m_User;
        config["P4CLIENT"] = client;
        config["P4CHARSET"] = conn.m_Charset;
        if (_Setup.m_Stream.empty())
        {
            std::string branchRoot = _Setup.m_BranchRoot;
            if (branchRoot.empty())
            {
                std::string depotPath = _Setup.m_DepotPath;
                while (!depotPath.empty() && (depotPath.back() == '/' || depotPath.back() == '.'))
                {
                    depotPath.pop_back();
                }
                const std::size_t nslash = depotPath.rfind('/');
                if (nslash != std::string::npos && nslash > 2)
                {
                    branchRoot = depotPath.substr(0, nslash);
                }
            }
            config["GITGUD_BRANCHROOT"] = branchRoot;
        }
        WriteConfigFile(root, config);

        auto ws = Open(root);
        ws->m_Passwords = _Passwords;
        if (_Setup.m_bSync)
        {
            ws->Run({"sync", "-q"});
        }
        return ws;
    }

    // ---- server queries -------------------------------------------------------------

    std::vector<StreamInfo> P4Workspace::ListStreams(
        const Connection& _Conn, const PasswordProvider& _Passwords)
    {
        std::vector<StreamInfo> out;
        const CommandResult r = P4Command::RunOrThrow(_Conn, {"streams"}, {}, _Passwords);
        for (const Record& s : r.m_Stats)
        {
            out.push_back(
                {Field(s, "Stream"), Field(s, "Name"), Field(s, "Parent"), Field(s, "Type")});
        }
        return out;
    }

    std::vector<DepotInfo> P4Workspace::ListDepots(
        const Connection& _Conn, const PasswordProvider& _Passwords)
    {
        std::vector<DepotInfo> out;
        const CommandResult r = P4Command::RunOrThrow(_Conn, {"depots"}, {}, _Passwords);
        for (const Record& d : r.m_Stats)
        {
            out.push_back({Field(d, "name"), Field(d, "type")});
        }
        return out;
    }

    std::vector<WorkspaceInfo> P4Workspace::ListWorkspaces(
        const Connection& _Conn, const PasswordProvider& _Passwords)
    {
        std::vector<WorkspaceInfo> out;
        const CommandResult r =
            P4Command::RunOrThrow(_Conn, {"clients", "-u", _Conn.m_User}, {}, _Passwords);
        for (const Record& c : r.m_Stats)
        {
            out.push_back(
                {Field(c, "client"), Field(c, "Root"), Field(c, "Stream"), Field(c, "Host")});
        }
        return out;
    }

    // ---- plumbing -------------------------------------------------------------------

    CommandResult P4Workspace::Run(
        const std::vector<std::string>& _Args, const Record& _Input) const
    {
        PasswordProvider passwords = m_Passwords;
        if (!passwords)
        {
            std::lock_guard<std::mutex> lock(g_DefaultMutex);
            passwords = g_DefaultPasswords;
        }
        return P4Command::Run(m_Conn, _Args, _Input, passwords);
    }

    CommandResult P4Workspace::RunOrThrow(
        const std::vector<std::string>& _Args, const Record& _Input) const
    {
        CommandResult r = Run(_Args, _Input);
        if (!r.Ok())
        {
            throw GitError(r.Message());
        }
        return r;
    }

    std::string P4Workspace::LocalArg(const std::string& _Path) const
    {
        std::string abs = m_Root + "/" + _Path;
        std::replace(abs.begin(), abs.end(), '/', '\\');
        return EscapePath(abs);
    }

    std::string P4Workspace::AllFiles() const
    {
        std::string abs = m_Root;
        std::replace(abs.begin(), abs.end(), '/', '\\');
        return EscapePath(abs) + "\\...";
    }

    std::string P4Workspace::RelativeFromClientOrLocal(const std::string& _Path) const
    {
        const std::string clientPrefix = "//" + m_Conn.m_Client + "/";
        if (StartsWithNoCase(_Path, clientPrefix))
        {
            return UnescapePath(_Path.substr(clientPrefix.size()));
        }
        const std::string local = ToSlashes(_Path);
        const std::string rootPrefix = m_Root + "/";
        if (StartsWithNoCase(local, rootPrefix))
        {
            return local.substr(rootPrefix.size());
        }
        return {};
    }

    std::string P4Workspace::StreamOf(const std::string& _DepotPath) const
    {
        if (!UsesStreams() || _DepotPath.rfind("//", 0) != 0)
        {
            return {};
        }
        // Stream depots default to a depth of one: //depot/stream/...
        const std::size_t ndepotEnd = _DepotPath.find('/', 2);
        if (ndepotEnd == std::string::npos)
        {
            return {};
        }
        const std::size_t nstreamEnd = _DepotPath.find('/', ndepotEnd + 1);
        return nstreamEnd == std::string::npos ? _DepotPath : _DepotPath.substr(0, nstreamEnd);
    }

    std::string P4Workspace::RelativeFromDepot(const std::string& _DepotPath) const
    {
        std::string depot = _DepotPath;
        // A file of a sibling stream: read it as the same path in ours.
        if (UsesStreams())
        {
            const std::string stream = StreamOf(depot);
            if (!stream.empty() && !StartsWithNoCase(stream, m_Stream) &&
                StreamOf(m_Stream + "/x") == m_Stream &&
                stream.substr(0, stream.rfind('/')) == m_Stream.substr(0, m_Stream.rfind('/')))
            {
                depot = m_Stream + depot.substr(stream.size());
            }
        }
        std::string result;
        for (const auto& [lhsRaw, rhsRaw] : m_View)
        {
            std::string lhs = lhsRaw;
            const bool bexclude = !lhs.empty() && lhs[0] == '-';
            if (!lhs.empty() && (lhs[0] == '-' || lhs[0] == '+'))
            {
                lhs.erase(0, 1);
            }
            bool bmatch = false;
            std::string mapped;
            if (lhs.size() >= 3 && lhs.compare(lhs.size() - 3, 3, "...") == 0)
            {
                const std::string prefix = lhs.substr(0, lhs.size() - 3);
                if (StartsWithNoCase(depot, prefix))
                {
                    bmatch = true;
                    std::string rhs = rhsRaw;
                    if (rhs.size() >= 3 && rhs.compare(rhs.size() - 3, 3, "...") == 0)
                    {
                        rhs.erase(rhs.size() - 3);
                    }
                    mapped = rhs + depot.substr(prefix.size());
                }
            }
            else if (StartsWithNoCase(depot, lhs) && depot.size() == lhs.size())
            {
                bmatch = true;
                mapped = rhsRaw;
            }
            if (bmatch)
            {
                result = bexclude ? std::string() : RelativeFromClientOrLocal(mapped);
            }
        }
        return result;
    }

    std::string P4Workspace::DepotFromRelative(const std::string& _Path) const
    {
        const std::string clientPath = "//" + m_Conn.m_Client + "/" + EscapePath(_Path);
        std::string result;
        for (const auto& [lhsRaw, rhs] : m_View)
        {
            std::string lhs = lhsRaw;
            const bool bexclude = !lhs.empty() && lhs[0] == '-';
            if (!lhs.empty() && (lhs[0] == '-' || lhs[0] == '+'))
            {
                lhs.erase(0, 1);
            }
            if (rhs.size() >= 3 && rhs.compare(rhs.size() - 3, 3, "...") == 0)
            {
                const std::string prefix = rhs.substr(0, rhs.size() - 3);
                if (StartsWithNoCase(clientPath, prefix))
                {
                    std::string base = lhs;
                    if (base.size() >= 3 && base.compare(base.size() - 3, 3, "...") == 0)
                    {
                        base.erase(base.size() - 3);
                    }
                    result = bexclude ? std::string() : base + clientPath.substr(prefix.size());
                }
            }
            else if (StartsWithNoCase(clientPath, rhs) && clientPath.size() == rhs.size())
            {
                result = bexclude ? std::string() : lhs;
            }
        }
        return result;
    }

    std::string P4Workspace::RevisionSuffix(const std::string& _Revision) const
    {
        if (_Revision.empty() || _Revision == "head" || _Revision == "HEAD" || _Revision == "index")
        {
            return "#have";
        }
        std::string rev = _Revision;
        bool bparent = false;
        if (rev.size() > 1 &&
            (rev.back() == '^' || (rev.size() > 2 && rev.compare(rev.size() - 2, 2, "~1") == 0)))
        {
            bparent = true;
            rev.erase(rev.back() == '^' ? rev.size() - 1 : rev.size() - 2);
        }
        if (!rev.empty() && rev[0] == '@')
        {
            rev.erase(0, 1);
        }
        // "@=12" is change 12's shelved copy; its "parent" is what the file
        // was shelved on top of, taken as the revision you have.
        if (!rev.empty() && rev[0] == '=')
        {
            return bparent ? std::string("#have") : "@" + rev;
        }
        if (!rev.empty() && std::all_of(rev.begin(), rev.end(), [](char _c)
                                { return std::isdigit(static_cast<unsigned char>(_c)) != 0; }))
        {
            const std::int64_t ichange = ToInt64(rev) - (bparent ? 1 : 0);
            return "@" + std::to_string(std::max<std::int64_t>(ichange, 0));
        }
        // A label name.
        return "@" + rev;
    }

    bool P4Workspace::PrintFile(
        const std::string& _FileSpec, std::string& _Out, bool* _pBinary) const
    {
        const CommandResult r = Run({"print", "-q", _FileSpec});
        if (!r.Ok() || r.m_Stats.empty())
        {
            return false;
        }
        // A deleted head revision prints nothing useful.
        const std::string action = Field(r.m_Stats.front(), "action");
        if (action == "delete" || action == "move/delete" || action == "purge" ||
            action == "archive")
        {
            return false;
        }
        _Out = r.m_Data;
        if (_pBinary)
        {
            *_pBinary = r.m_bBinary;
        }
        return true;
    }

    std::string P4Workspace::ReadWorkFile(const std::string& _Path, bool& _bExists) const
    {
        const fs::path abs = fs::u8path(m_Root) / fs::u8path(_Path);
        std::ifstream in(abs, std::ios::binary);
        _bExists = static_cast<bool>(in) && fs::is_regular_file(abs);
        if (!_bExists)
        {
            return {};
        }
        std::ostringstream ss;
        ss << in.rdbuf();
        return ToLf(ss.str());
    }

    std::vector<Record> P4Workspace::Opened(const std::string& _Change) const
    {
        std::vector<std::string> args = {"opened"};
        if (!_Change.empty())
        {
            args.emplace_back("-c");
            args.push_back(_Change);
        }
        return RunOrThrow(args).m_Stats;
    }

    std::vector<Record> P4Workspace::PendingResolves() const
    {
        const CommandResult r = Run({"resolve", "-n"});
        return r.m_Stats;
    }

    void P4Workspace::Unsupported(const std::string& _What) const
    {
        throw GitError(_What + " isn't available in a Perforce workspace.");
    }

    std::string P4Workspace::UserEmail() const
    {
        const CommandResult r = Run({"user", "-o", m_Conn.m_User});
        return r.m_Stats.empty() ? std::string() : Field(r.m_Stats.front(), "Email");
    }

    void P4Workspace::RequireNothingOpen(const std::string& _What) const
    {
        const std::vector<Record> opened = Opened();
        if (!opened.empty())
        {
            throw GitError(_What +
                           " needs a workspace with no open files: submit, shelve (stash), or "
                           "revert the " +
                           std::to_string(opened.size()) + " open file(s) first.");
        }
    }

    // ---- status ----------------------------------------------------------------------

    std::vector<git::StatusEntry> P4Workspace::Status() const
    {
        std::map<std::string, git::StatusEntry> byPath;
        const auto actionCode = [](const std::string& _Action) -> char
        {
            if (_Action == "add" || _Action == "move/add" || _Action == "branch" ||
                _Action == "import")
            {
                return 'A';
            }
            if (_Action == "delete" || _Action == "move/delete")
            {
                return 'D';
            }
            return 'M';
        };

        for (const Record& o : Opened())
        {
            const std::string rel = RelativeFromClientOrLocal(Field(o, "clientFile"));
            if (rel.empty())
            {
                continue;
            }
            git::StatusEntry& e = byPath[rel];
            e.m_Path = rel;
            e.m_bStaged = true;
            e.m_cCode = actionCode(Field(o, "action"));
        }

        // Changed on disk, not opened: `p4 status` (reconcile -n) finds edits,
        // deletions, and files the depot doesn't have.
        const CommandResult st = Run({"status", AllFiles()});
        if (!st.Ok())
        {
            throw GitError(st.Message());
        }
        for (const Record& s : st.m_Stats)
        {
            std::string rel = RelativeFromClientOrLocal(Field(s, "clientFile"));
            if (rel.empty())
            {
                rel = ToSlashes(Field(s, "localFile"));
            }
            if (rel.empty() || rel == g_szConfigFile)
            {
                continue;
            }
            git::StatusEntry& e = byPath[rel];
            if (e.m_bStaged)
            {
                continue; // opened files are staged whole
            }
            e.m_Path = rel;
            e.m_bUnstaged = true;
            const std::string action = Field(s, "action");
            e.m_cCode = action == "add" ? '?' : actionCode(action);
        }

        for (const Record& r : PendingResolves())
        {
            const std::string rel = RelativeFromClientOrLocal(Field(r, "clientFile"));
            if (rel.empty())
            {
                continue;
            }
            git::StatusEntry& e = byPath[rel];
            e.m_Path = rel;
            e.m_cCode = 'U';
            e.m_bUnstaged = true;
        }

        std::vector<git::StatusEntry> out;
        out.reserve(byPath.size());
        for (auto& [path, entry] : byPath)
        {
            out.push_back(std::move(entry));
        }
        return out;
    }

    // ---- opening files ("staging") --------------------------------------------------

    void P4Workspace::Stage(const std::vector<std::string>& _Paths)
    {
        if (_Paths.empty())
        {
            return;
        }
        std::set<std::string> conflicted;
        for (const Record& r : PendingResolves())
        {
            conflicted.insert(RelativeFromClientOrLocal(Field(r, "clientFile")));
        }
        std::vector<std::string> resolve = {"resolve", "-ay"};
        std::vector<std::string> reconcile = {"reconcile"};
        for (const std::string& path : _Paths)
        {
            (conflicted.count(path) ? resolve : reconcile).push_back(LocalArg(path));
        }
        // A conflicted file the user edited: staging it accepts the file as
        // it is on disk, like `git add` on a resolved file.
        if (resolve.size() > 2)
        {
            RunOrThrow(resolve);
        }
        if (reconcile.size() > 1)
        {
            const CommandResult r = Run(reconcile);
            if (!r.Ok())
            {
                throw GitError(r.Message());
            }
        }
    }

    void P4Workspace::Unstage(const std::vector<std::string>& _Paths)
    {
        if (_Paths.empty())
        {
            return;
        }
        std::vector<std::string> args = {"revert", "-k"};
        for (const std::string& path : _Paths)
        {
            args.push_back(LocalArg(path));
        }
        const CommandResult r = Run(args);
        if (!r.Ok())
        {
            throw GitError(r.Message());
        }
    }

    std::vector<std::size_t> P4Workspace::StagedLines(const std::string& _Path) const
    {
        const git::FileDiff staged = DiffFile(_Path, git::DiffTarget::Staged, {});
        if (staged.m_Path.empty())
        {
            return {};
        }
        std::vector<std::size_t> out;
        std::size_t nindex = 0;
        for (const git::DiffHunk& h : staged.m_Hunks)
        {
            for (const git::DiffLine& l : h.m_Lines)
            {
                if (l.m_cOrigin == '+' || l.m_cOrigin == '-')
                {
                    out.push_back(nindex);
                }
                ++nindex;
            }
        }
        return out;
    }

    void P4Workspace::SetStagedLines(const std::string& _Path,
        const std::vector<std::size_t>& _Lines, std::size_t _ExpectedLineCount)
    {
        const git::FileDiff combined = DiffFile(_Path, git::DiffTarget::Head, {});
        std::size_t ntotal = 0;
        std::size_t nchanged = 0;
        for (const git::DiffHunk& h : combined.m_Hunks)
        {
            for (const git::DiffLine& l : h.m_Lines)
            {
                nchanged += (l.m_cOrigin == '+' || l.m_cOrigin == '-') ? 1 : 0;
                ++ntotal;
            }
        }
        if (ntotal != _ExpectedLineCount)
        {
            throw GitError("'" + _Path + "' changed on disk; refresh and try again");
        }
        if (_Lines.empty())
        {
            Unstage({_Path});
            return;
        }
        if (_Lines.size() == nchanged)
        {
            Stage({_Path});
            return;
        }
        Unsupported("Staging part of a file (Perforce opens whole files)");
    }

    void P4Workspace::DiscardLines(const std::string& _Path, const std::vector<std::size_t>& _Lines,
        std::size_t _ExpectedLineCount, const std::function<bool(const std::string&)>& _RemoveFile)
    {
        const git::FileDiff combined = DiffFile(_Path, git::DiffTarget::Head, {});
        std::vector<const git::DiffLine*> flat;
        for (const git::DiffHunk& h : combined.m_Hunks)
        {
            for (const git::DiffLine& l : h.m_Lines)
            {
                flat.push_back(&l);
            }
        }
        if (flat.size() != _ExpectedLineCount)
        {
            throw GitError("'" + _Path + "' changed on disk; refresh and try again");
        }
        const std::set<std::size_t> chosen(_Lines.begin(), _Lines.end());
        std::size_t nchanged = 0;
        for (const git::DiffLine* pl : flat)
        {
            nchanged += (pl->m_cOrigin == '+' || pl->m_cOrigin == '-') ? 1 : 0;
        }
        if (chosen.size() >= nchanged)
        {
            DiscardChanges({_Path}, _RemoveFile);
            return;
        }

        // Rebuild the file: the have revision's lines, with each hunk's lines
        // taken from the new side unless chosen for discarding.
        std::string haveText;
        const bool bhave = PrintFile(LocalArg(_Path) + "#have", haveText);
        const std::vector<std::string> oldLines =
            SplitLines(bhave ? ToLf(haveText) : std::string());
        bool bworkExists = false;
        const std::string work = ReadWorkFile(_Path, bworkExists);
        const bool btrailingNewline = !work.empty() && work.back() == '\n';

        std::vector<std::string> out;
        std::size_t nold = 0; // 0-based next old line to copy
        std::size_t nflat = 0;
        for (const git::DiffHunk& h : combined.m_Hunks)
        {
            const std::size_t nhunkOld =
                h.m_iOldStart > 0 ? static_cast<std::size_t>(h.m_iOldStart - 1) : 0;
            while (nold < nhunkOld && nold < oldLines.size())
            {
                out.push_back(oldLines[nold++]);
            }
            for (const git::DiffLine& l : h.m_Lines)
            {
                const bool bdiscard = chosen.count(nflat++) != 0;
                if (l.m_cOrigin == ' ')
                {
                    out.push_back(l.m_Content);
                    ++nold;
                }
                else if (l.m_cOrigin == '-')
                {
                    if (bdiscard)
                    {
                        out.push_back(l.m_Content); // put the removed line back
                    }
                    ++nold;
                }
                else if (l.m_cOrigin == '+')
                {
                    if (!bdiscard)
                    {
                        out.push_back(l.m_Content);
                    }
                }
            }
        }
        while (nold < oldLines.size())
        {
            out.push_back(oldLines[nold++]);
        }
        std::string text;
        for (std::size_t i = 0; i < out.size(); ++i)
        {
            text += out[i];
            if (i + 1 < out.size() || btrailingNewline)
            {
                text += "\n";
            }
        }
        std::ofstream file(
            fs::u8path(m_Root) / fs::u8path(_Path), std::ios::binary | std::ios::trunc);
        if (!file)
        {
            throw GitError("Could not write '" + _Path + "'");
        }
        file << text;
    }

    void P4Workspace::DiscardChanges(const std::vector<std::string>& _Paths,
        const std::function<bool(const std::string&)>& _RemoveFile)
    {
        if (_Paths.empty())
        {
            return;
        }
        std::map<std::string, std::string> openedAction;
        for (const Record& o : Opened())
        {
            openedAction[RelativeFromClientOrLocal(Field(o, "clientFile"))] = Field(o, "action");
        }

        std::vector<std::string> revert = {"revert"};
        std::vector<std::string> restore = {"sync", "-f"};
        std::vector<std::string> remove;
        for (const std::string& path : _Paths)
        {
            const auto it = openedAction.find(path);
            if (it != openedAction.end())
            {
                revert.push_back(LocalArg(path));
                if (it->second == "add" || it->second == "move/add" || it->second == "branch")
                {
                    remove.push_back(path); // not in the depot: the file goes too
                }
                continue;
            }
            std::string ignored;
            if (PrintFile(LocalArg(path) + "#have", ignored))
            {
                restore.push_back(LocalArg(path) + "#have");
            }
            else
            {
                remove.push_back(path); // untracked
            }
        }
        if (revert.size() > 1)
        {
            RunOrThrow(revert);
        }
        if (restore.size() > 2)
        {
            RunOrThrow(restore);
        }
        for (const std::string& path : remove)
        {
            const fs::path abs = fs::u8path(m_Root) / fs::u8path(path);
            std::error_code ec;
            if (!fs::exists(abs, ec))
            {
                continue;
            }
            if (_RemoveFile)
            {
                if (!_RemoveFile(abs.u8string()))
                {
                    throw GitError("Could not remove '" + path + "'");
                }
            }
            else if (!fs::remove(abs, ec) || ec)
            {
                throw GitError("Could not remove '" + path + "'");
            }
        }
    }

    void P4Workspace::AddToGitignore(const std::string& _Pattern)
    {
        const fs::path file = fs::u8path(m_Root) / ".p4ignore";
        std::string existing;
        {
            std::ifstream in(file, std::ios::binary);
            std::ostringstream ss;
            ss << in.rdbuf();
            existing = ss.str();
        }
        std::ofstream out(file, std::ios::binary | std::ios::app);
        if (!out)
        {
            throw GitError("Could not write .p4ignore");
        }
        if (!existing.empty() && existing.back() != '\n')
        {
            out << "\n";
        }
        out << _Pattern << "\n";
    }

    bool P4Workspace::ReadFileVersion(
        const std::string& _Path, const std::string& _Revision, std::string& _Out) const
    {
        if (_Revision == "workdir")
        {
            bool bexists = false;
            _Out = ReadWorkFile(_Path, bexists);
            return bexists;
        }
        if (_Revision == "index")
        {
            // No index: an opened file's staged content is the file itself.
            for (const Record& o : Opened())
            {
                if (RelativeFromClientOrLocal(Field(o, "clientFile")) == _Path)
                {
                    const std::string action = Field(o, "action");
                    if (action == "delete" || action == "move/delete")
                    {
                        return false;
                    }
                    bool bexists = false;
                    _Out = ReadWorkFile(_Path, bexists);
                    return bexists;
                }
            }
        }
        std::string text;
        if (!PrintFile(LocalArg(_Path) + RevisionSuffix(_Revision), text))
        {
            return false;
        }
        _Out = ToLf(text);
        return true;
    }

    // ---- submitting ---------------------------------------------------------------------

    std::string P4Workspace::NewChange(
        const std::string& _Description, const std::vector<std::string>& _Files)
    {
        CommandResult tmpl = RunOrThrow({"change", "-o"});
        if (tmpl.m_Stats.empty())
        {
            throw GitError("Could not prepare a changelist");
        }
        Record spec = SpecForInput(tmpl.m_Stats.front());
        for (auto it = spec.begin(); it != spec.end();)
        {
            it = it->first.rfind("Files", 0) == 0 ? spec.erase(it) : std::next(it);
        }
        for (std::size_t i = 0; i < _Files.size(); ++i)
        {
            spec["Files" + std::to_string(i)] = _Files[i];
        }
        spec["Description"] = _Description.empty() ? std::string("(no description)") : _Description;
        const CommandResult r = RunOrThrow({"change", "-i"}, spec);
        std::string all;
        for (const std::string& line : r.m_Info)
        {
            all += line + "\n";
        }
        const std::string change = NumberAfter(all, "Change");
        if (change.empty())
        {
            throw GitError("p4 change did not report a changelist number");
        }
        return change;
    }

    std::string P4Workspace::SubmitChange(const std::string& _Change)
    {
        const CommandResult r = Run({"submit", "-c", _Change});
        if (!r.Ok())
        {
            throw GitError(r.Message());
        }
        for (const Record& s : r.m_Stats)
        {
            const std::string submitted = Field(s, "submittedChange");
            if (!submitted.empty())
            {
                return submitted;
            }
        }
        std::string all;
        for (const std::string& line : r.m_Info)
        {
            all += line + "\n";
        }
        const std::string renamed = NumberAfter(all, "renamed change");
        return renamed.empty() ? _Change : renamed;
    }

    std::string P4Workspace::SubmitDefault(const std::string& _Message)
    {
        std::vector<std::string> files;
        for (const Record& o : Opened("default"))
        {
            files.push_back(Field(o, "depotFile"));
        }
        if (files.empty())
        {
            throw GitError("Nothing to commit: no files are opened (staged).");
        }
        const std::vector<Record> resolves = PendingResolves();
        if (!resolves.empty())
        {
            throw GitError("Resolve the conflicted files before submitting.");
        }
        const std::string change = NewChange(_Message, files);
        try
        {
            return SubmitChange(change);
        }
        catch (const GitError&)
        {
            // Leave things as they were: files back in the default
            // changelist, the numbered one deleted.
            Run({"reopen", "-c", "default", "//" + m_Conn.m_Client + "/..."});
            Run({"change", "-d", change});
            throw;
        }
    }

    std::string P4Workspace::Commit(const std::string& _Message)
    {
        const std::string merge = m_Config["GITGUD_MERGE_CHANGE"];
        if (merge.empty())
        {
            return SubmitDefault(_Message);
        }
        // Finishing a merge/revert/cherry-pick: like a git merge commit it
        // takes everything staged, under the message given now.
        if (!PendingResolves().empty())
        {
            throw GitError("Resolve the conflicted files before submitting.");
        }
        Run({"reopen", "-c", merge, "//" + m_Conn.m_Client + "/..."});
        CommandResult spec = RunOrThrow({"change", "-o", merge});
        if (!spec.m_Stats.empty() && !_Message.empty())
        {
            Record in = SpecForInput(spec.m_Stats.front());
            in["Description"] = _Message;
            RunOrThrow({"change", "-i"}, in);
        }
        const std::string submitted = SubmitChange(merge);
        m_Config.erase("GITGUD_MERGE_CHANGE");
        SaveConfig();
        return submitted;
    }

    std::string P4Workspace::AmendCommit(const std::string&)
    {
        Unsupported("Amending a submitted changelist");
        return {};
    }

    std::string P4Workspace::UndoLastCommit()
    {
        Unsupported("Taking back a submit (use Revert to submit its opposite)");
        return {};
    }

    git::FileDiff P4Workspace::DiffFile(
        const std::string& _Path, git::DiffTarget _Target, const git::DiffOptions& _Options) const
    {
        std::string action;
        for (const Record& o : Opened())
        {
            if (RelativeFromClientOrLocal(Field(o, "clientFile")) == _Path)
            {
                action = Field(o, "action");
                break;
            }
        }
        const bool bopened = !action.empty();
        if ((_Target == git::DiffTarget::Unstaged && bopened) ||
            (_Target == git::DiffTarget::Staged && !bopened))
        {
            return {};
        }
        std::string haveText;
        const bool bhave = PrintFile(LocalArg(_Path) + "#have", haveText);
        bool bwork = false;
        const std::string work = ReadWorkFile(_Path, bwork);
        if (bhave == bwork && (!bhave || ToLf(haveText) == work))
        {
            return {};
        }
        git::FileDiff d = git::internal::DiffFileVersions(_Path,
            Version(bhave ? ToLf(haveText) : std::string(), bhave), _Path, Version(work, bwork),
            _Options);
        return d;
    }

    void P4Workspace::StageHunk(const std::string&, std::size_t)
    {
        Unsupported("Staging one hunk (Perforce opens whole files)");
    }

    void P4Workspace::UnstageHunk(const std::string&, std::size_t)
    {
        Unsupported("Unstaging one hunk (Perforce opens whole files)");
    }

    // ---- config / remotes ---------------------------------------------------------------

    std::string P4Workspace::GetConfig(const std::string& _Key) const
    {
        const auto local = m_Config.find("GITGUD_" + _Key);
        if (local != m_Config.end())
        {
            return local->second;
        }
        if (_Key == "user.name")
        {
            const CommandResult r = Run({"user", "-o", m_Conn.m_User});
            const std::string full =
                r.m_Stats.empty() ? std::string() : Field(r.m_Stats.front(), "FullName");
            return full.empty() ? m_Conn.m_User : full;
        }
        if (_Key == "user.email")
        {
            return UserEmail();
        }
        if (_Key == "p4.port")
        {
            return m_Conn.m_Port;
        }
        if (_Key == "p4.user")
        {
            return m_Conn.m_User;
        }
        if (_Key == "p4.client")
        {
            return m_Conn.m_Client;
        }
        if (_Key == "p4.stream")
        {
            return m_Stream;
        }
        if (_Key == "p4.depotRoot")
        {
            // The depot folder the workspace root maps to: the stream, or
            // the first view line's depot side ("//depot/proj/main").
            if (UsesStreams())
            {
                return m_Stream;
            }
            for (const auto& [lhs, rhs] : m_View)
            {
                if (!lhs.empty() && lhs[0] != '-')
                {
                    std::string root = lhs[0] == '+' ? lhs.substr(1) : lhs;
                    if (root.size() >= 4 && root.compare(root.size() - 4, 4, "/...") == 0)
                    {
                        root.erase(root.size() - 4);
                    }
                    return root;
                }
            }
            return "//" + m_Conn.m_Client;
        }
        return {};
    }

    void P4Workspace::SetConfig(const std::string& _Key, const std::string& _Value)
    {
        if (_Key == "p4.port")
        {
            m_Config["P4PORT"] = _Value;
            m_Conn.m_Port = _Value;
        }
        else if (_Key == "p4.user")
        {
            m_Config["P4USER"] = _Value;
            m_Conn.m_User = _Value;
        }
        else if (_Key == "p4.charset")
        {
            m_Config["P4CHARSET"] = _Value;
            m_Conn.m_Charset = _Value;
        }
        else
        {
            m_Config["GITGUD_" + _Key] = _Value;
        }
        SaveConfig();
    }

    std::vector<git::RemoteInfo> P4Workspace::Remotes() const
    {
        return {{"server", m_Conn.m_Port}};
    }

    void P4Workspace::AddRemote(const std::string&, const std::string&)
    {
        Unsupported("Adding a remote (a workspace has one server)");
    }

    void P4Workspace::RemoveRemote(const std::string&)
    {
        Unsupported("Removing the server");
    }

    void P4Workspace::SetRemoteUrl(const std::string&, const std::string& _Url)
    {
        SetConfig("p4.port", _Url);
    }

    void P4Workspace::RenameRemote(const std::string&, const std::string&)
    {
        Unsupported("Renaming the server");
    }

    void P4Workspace::SetUpstream(const std::string&, const std::string&)
    {
        // Every stream already flows to its parent; nothing to track.
    }

    // ---- the server -------------------------------------------------------------------------

    void P4Workspace::Fetch(const std::string&)
    {
        // Perforce has nothing to download ahead of time; checking the
        // connection (and logging in) is the useful part.
        RunOrThrow({"changes", "-m", "1", "-s", "submitted", "//" + m_Conn.m_Client + "/..."});
    }

    std::vector<std::string> P4Workspace::FetchAll()
    {
        Fetch("server");
        return {"server"};
    }

    void P4Workspace::Push(const std::string&, bool, bool)
    {
        // Commit submits straight to the server: there is never anything to push.
    }

    void P4Workspace::PushTags(const std::string&)
    {
        // Labels live on the server already.
    }

    void P4Workspace::PushBranch(const std::string&, const std::string&, const std::string&, bool)
    {
        // Streams and shelves live on the server already.
    }

    void P4Workspace::DeleteRemoteBranch(const std::string&, const std::string& _Branch)
    {
        // Shelves are deleted with their changelist (StashDrop); a stream
        // with DeleteBranch. Shelf branches have no server copy to remove.
        if (_Branch.rfind("shelves/", 0) == 0)
        {
            return;
        }
        DeleteBranch(_Branch);
    }

    std::vector<std::string> P4Workspace::AutoResolve()
    {
        Run({"resolve", "-am"});
        std::vector<std::string> out;
        for (const Record& r : PendingResolves())
        {
            const std::string rel = RelativeFromClientOrLocal(Field(r, "clientFile"));
            if (!rel.empty())
            {
                out.push_back(rel);
            }
        }
        return out;
    }

    git::MergeResult P4Workspace::Pull(const std::string&)
    {
        git::MergeResult result;
        // Refuse up front, as git does, when getting latest would have to
        // overwrite changes the user made without opening the files.
        const CommandResult preview = Run({"sync", "-n"});
        if (!preview.Ok())
        {
            throw GitError(preview.Message());
        }
        std::vector<std::string> blocked;
        // Opened files show up as info lines ("is opened and not being
        // changed"): syncing them schedules a resolve.
        bool bany = !preview.m_Stats.empty() || !preview.m_Info.empty();
        std::vector<std::string> notes = preview.m_Warnings;
        notes.insert(notes.end(), preview.m_Info.begin(), preview.m_Info.end());
        for (const std::string& w : notes)
        {
            if (w.find("can't update modified file") != std::string::npos ||
                w.find("Can't clobber writable file") != std::string::npos)
            {
                const std::size_t nfile = w.rfind(" file ");
                blocked.push_back(nfile == std::string::npos
                                      ? w
                                      : RelativeFromClientOrLocal(w.substr(nfile + 6)));
            }
        }
        for (const Record& s : preview.m_Stats)
        {
            const std::string action = Field(s, "action");
            if (action.find("can't") != std::string::npos)
            {
                blocked.push_back(RelativeFromClientOrLocal(Field(s, "clientFile")));
            }
        }
        if (!blocked.empty())
        {
            std::string list;
            for (const std::string& b : blocked)
            {
                list += "\n  " + b;
            }
            throw GitError(
                "Your local changes to these files would be overwritten by getting latest:" + list +
                "\nStage (open) them first so the incoming changes merge, or discard them.");
        }
        if (!bany)
        {
            result.m_Kind = git::MergeResult::Kind::UpToDate;
            result.m_Message = "Already up to date";
            return result;
        }
        const CommandResult synced = Run({"sync"});
        if (!synced.Ok())
        {
            throw GitError(synced.Message());
        }
        result.m_ConflictedPaths = AutoResolve();
        if (!result.m_ConflictedPaths.empty())
        {
            result.m_Kind = git::MergeResult::Kind::Conflicts;
            result.m_Message = "Got latest; " + std::to_string(result.m_ConflictedPaths.size()) +
                               " file(s) need resolving";
            return result;
        }
        result.m_Kind = git::MergeResult::Kind::FastForward;
        result.m_Message = "Got latest (" + std::to_string(synced.m_Stats.size()) + " file(s))";
        return result;
    }

    git::AheadBehind P4Workspace::GetAheadBehind() const
    {
        git::AheadBehind ab;
        ab.m_bHasUpstream = true;
        ab.m_Upstream = UsesStreams() ? m_Stream : std::string("server");
        ab.m_UpstreamRemote = "server";
        const std::string all = "//" + m_Conn.m_Client + "/...";
        const std::string have = HeadOid();
        const CommandResult r = Run({"changes", "-m", "1000", "-s", "submitted",
            have.empty() ? all : all + "@" + std::to_string(ToInt64(have) + 1) + ",#head"});
        if (r.Ok())
        {
            ab.m_Behind = r.m_Stats.size();
        }
        return ab;
    }

} // namespace gitgud::p4
