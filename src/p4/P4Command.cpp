#include "p4/P4Command.h"

#include "git/Repository.h"
#include "platform/Process.h"

#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <set>

namespace gitgud::p4
{

    namespace
    {

        // ---- Python marshal, version 0 (what `p4 -G` speaks) ------------------
        void PutInt32(std::string& _Out, std::int32_t _iValue)
        {
            const auto u = static_cast<std::uint32_t>(_iValue);
            _Out.push_back(static_cast<char>(u & 0xff));
            _Out.push_back(static_cast<char>((u >> 8) & 0xff));
            _Out.push_back(static_cast<char>((u >> 16) & 0xff));
            _Out.push_back(static_cast<char>((u >> 24) & 0xff));
        }

        void PutString(std::string& _Out, const std::string& _Value)
        {
            _Out.push_back('s');
            PutInt32(_Out, static_cast<std::int32_t>(_Value.size()));
            _Out += _Value;
        }

        struct Reader
        {
            const std::string& m_Data;
            std::size_t m_nPos = 0;

            bool Int32(std::int32_t& _iOut)
            {
                if (m_nPos + 4 > m_Data.size())
                {
                    return false;
                }
                std::uint32_t u = 0;
                for (int i = 3; i >= 0; --i)
                {
                    u = (u << 8) | static_cast<unsigned char>(m_Data[m_nPos + static_cast<std::size_t>(i)]);
                }
                m_nPos += 4;
                _iOut = static_cast<std::int32_t>(u);
                return true;
            }

            // One scalar (string or int) as text. False on anything else.
            bool Scalar(std::string& _Out)
            {
                if (m_nPos >= m_Data.size())
                {
                    return false;
                }
                const char ctype = m_Data[m_nPos++];
                if (ctype == 's' || ctype == 't' || ctype == 'u')
                {
                    std::int32_t ilen = 0;
                    if (!Int32(ilen) || ilen < 0 ||
                        m_nPos + static_cast<std::size_t>(ilen) > m_Data.size())
                    {
                        return false;
                    }
                    _Out.assign(m_Data, m_nPos, static_cast<std::size_t>(ilen));
                    m_nPos += static_cast<std::size_t>(ilen);
                    return true;
                }
                if (ctype == 'i')
                {
                    std::int32_t ivalue = 0;
                    if (!Int32(ivalue))
                    {
                        return false;
                    }
                    _Out = std::to_string(ivalue);
                    return true;
                }
                return false;
            }
        };

        std::mutex g_TicketMutex;
        std::map<std::string, std::string> g_Tickets; // "port|user" -> ticket
        std::set<std::string> g_UnicodePorts;         // servers that needed -C utf8

        std::string TicketKey(const Connection& _Conn)
        {
            return _Conn.m_Port + "|" + _Conn.m_User;
        }

        std::string EnvString(const char* _szName)
        {
            const char* sz = std::getenv(_szName);
            return sz ? std::string(sz) : std::string();
        }

        std::vector<std::string> GlobalArgs(const Connection& _Conn, const std::string& _Ticket,
            const std::string& _Charset, bool _bMarshal)
        {
            std::vector<std::string> args;
            args.push_back(P4Command::Executable());
            if (_bMarshal)
            {
                args.emplace_back("-G");
            }
            args.emplace_back("-zprog=GitGud");
            if (!_Conn.m_Port.empty())
            {
                args.emplace_back("-p");
                args.push_back(_Conn.m_Port);
            }
            if (!_Conn.m_User.empty())
            {
                args.emplace_back("-u");
                args.push_back(_Conn.m_User);
            }
            // Always name a client, so a P4CLIENT from the user's environment
            // never stands in for "none".
            args.emplace_back("-c");
            args.push_back(_Conn.m_Client.empty() ? std::string("gitgud-none") : _Conn.m_Client);
            if (!_Charset.empty())
            {
                args.emplace_back("-C");
                args.push_back(_Charset);
            }
            if (!_Ticket.empty())
            {
                args.emplace_back("-P");
                args.push_back(_Ticket);
            }
            if (!_Conn.m_Dir.empty())
            {
                args.emplace_back("-d");
                args.push_back(_Conn.m_Dir);
            }
            return args;
        }

        CommandResult Parse(const platform::ProcessResult& _Process)
        {
            CommandResult out;
            out.m_iExitCode = _Process.m_iExitCode;
            if (!_Process.m_bStarted)
            {
                out.m_Errors.push_back("Could not run p4: " + _Process.m_StartError);
                return out;
            }
            for (Record& rec : UnmarshalRecords(_Process.m_Output))
            {
                const std::string code = Field(rec, "code");
                if (code == "stat")
                {
                    out.m_Stats.push_back(std::move(rec));
                }
                else if (code == "info")
                {
                    out.m_Info.push_back(Field(rec, "data"));
                }
                else if (code == "text" || code == "binary")
                {
                    out.m_Data += Field(rec, "data");
                    out.m_bBinary = out.m_bBinary || code == "binary";
                }
                else if (code == "error")
                {
                    std::string data = Field(rec, "data");
                    while (!data.empty() && (data.back() == '\n' || data.back() == '\r'))
                    {
                        data.pop_back();
                    }
                    const int iseverity = std::atoi(Field(rec, "severity", "3").c_str());
                    (iseverity >= 3 ? out.m_Errors : out.m_Warnings).push_back(data);
                }
            }
            // p4 writes some failures (bad flags, no server) as plain stderr.
            if (!_Process.m_Error.empty())
            {
                std::string err = _Process.m_Error;
                while (!err.empty() && (err.back() == '\n' || err.back() == '\r'))
                {
                    err.pop_back();
                }
                if (!err.empty())
                {
                    out.m_Errors.push_back(err);
                }
            }
            if (out.m_Errors.empty() && out.m_Stats.empty() && out.m_Info.empty() &&
                out.m_Warnings.empty() && out.m_Data.empty() && _Process.m_iExitCode != 0)
            {
                out.m_Errors.push_back("p4 failed (exit code " + std::to_string(_Process.m_iExitCode) + ")");
            }
            return out;
        }

        bool IsUnicodeError(const CommandResult& _Result)
        {
            for (const std::string& e : _Result.m_Errors)
            {
                if (e.find("Unicode server permits only unicode enabled clients") != std::string::npos)
                {
                    return true;
                }
            }
            return false;
        }

        bool HasLoginError(const CommandResult& _Result)
        {
            for (const std::string& e : _Result.m_Errors)
            {
                if (P4Command::IsLoginError(e))
                {
                    return true;
                }
            }
            return false;
        }

    } // namespace

    // ---- marshal ---------------------------------------------------------------

    std::string MarshalRecord(const Record& _Record)
    {
        std::string out;
        out.push_back('{');
        for (const auto& [key, value] : _Record)
        {
            PutString(out, key);
            PutString(out, value);
        }
        out.push_back('0');
        return out;
    }

    std::vector<Record> UnmarshalRecords(const std::string& _Data)
    {
        std::vector<Record> out;
        Reader r{_Data};
        while (r.m_nPos < _Data.size())
        {
            if (_Data[r.m_nPos] != '{')
            {
                break;
            }
            ++r.m_nPos;
            Record rec;
            bool bclosed = false;
            while (r.m_nPos < _Data.size())
            {
                if (_Data[r.m_nPos] == '0')
                {
                    ++r.m_nPos;
                    bclosed = true;
                    break;
                }
                std::string key;
                std::string value;
                if (!r.Scalar(key) || !r.Scalar(value))
                {
                    return out;
                }
                rec[key] = std::move(value);
            }
            if (!bclosed)
            {
                break;
            }
            out.push_back(std::move(rec));
        }
        return out;
    }

    // ---- results -----------------------------------------------------------------

    std::string CommandResult::Message() const
    {
        const std::vector<std::string>& lines = m_Errors.empty() ? m_Warnings : m_Errors;
        std::string out;
        for (const std::string& line : lines)
        {
            if (!out.empty())
            {
                out += "\n";
            }
            out += line;
        }
        return out;
    }

    // ---- running p4 -------------------------------------------------------------

    std::string P4Command::Executable()
    {
        const std::string configured = EnvString("GITGUD_P4");
        std::error_code ec;
        if (!configured.empty() && std::filesystem::exists(std::filesystem::u8path(configured), ec))
        {
            return configured;
        }
        std::string found = platform::FindProgram("p4");
        if (!found.empty())
        {
            return found;
        }
        for (const char* szvar : {"ProgramFiles", "ProgramW6432"})
        {
            const std::string base = EnvString(szvar);
            if (base.empty())
            {
                continue;
            }
            const std::filesystem::path candidate = std::filesystem::u8path(base) / "Perforce" / "p4.exe";
            if (std::filesystem::exists(candidate, ec))
            {
                return candidate.u8string();
            }
        }
        return {};
    }

    std::string P4Command::TicketFor(const Connection& _Conn)
    {
        std::lock_guard<std::mutex> lock(g_TicketMutex);
        const auto it = g_Tickets.find(TicketKey(_Conn));
        return it == g_Tickets.end() ? std::string() : it->second;
    }

    void P4Command::ClearTickets()
    {
        std::lock_guard<std::mutex> lock(g_TicketMutex);
        g_Tickets.clear();
    }

    bool P4Command::IsLoginError(const std::string& _Message)
    {
        return _Message.find("P4PASSWD") != std::string::npos ||
               _Message.find("please login again") != std::string::npos ||
               _Message.find("Password invalid") != std::string::npos;
    }

    CommandResult P4Command::Run(const Connection& _Conn, const std::vector<std::string>& _Args,
        const Record& _Input, const PasswordProvider& _Passwords)
    {
        if (Executable().empty())
        {
            CommandResult missing;
            missing.m_Errors.emplace_back(
                "The p4 command-line client was not found. Install it, or set GITGUD_P4 to p4.exe.");
            return missing;
        }

        std::string charset = _Conn.m_Charset;
        if (charset.empty())
        {
            std::lock_guard<std::mutex> lock(g_TicketMutex);
            if (g_UnicodePorts.count(_Conn.m_Port) != 0)
            {
                charset = "utf8";
            }
        }

        const auto runOnce = [&]()
        {
            std::vector<std::string> args = GlobalArgs(_Conn, TicketFor(_Conn), charset, true);
            args.insert(args.end(), _Args.begin(), _Args.end());
            const std::string input = _Input.empty() ? std::string() : MarshalRecord(_Input);
            return Parse(platform::RunProcess(args, _Conn.m_Dir, input));
        };

        CommandResult result = runOnce();
        if (charset.empty() && IsUnicodeError(result))
        {
            {
                std::lock_guard<std::mutex> lock(g_TicketMutex);
                g_UnicodePorts.insert(_Conn.m_Port);
            }
            charset = "utf8";
            result = runOnce();
        }

        // Ask, log in, retry. A refused password is reported back once with
        // `_bRejected` (the store forgets it) and the provider decides
        // whether to answer again.
        bool brejected = false;
        for (int iattempt = 0; _Passwords && HasLoginError(result) && iattempt < 3; ++iattempt)
        {
            std::string password;
            if (!_Passwords(_Conn.m_Port, _Conn.m_User, brejected, password))
            {
                break;
            }
            std::string loginError;
            if (!Login(_Conn, password, loginError))
            {
                brejected = true;
                result.m_Errors = {loginError};
                continue;
            }
            result = runOnce();
        }
        return result;
    }

    CommandResult P4Command::RunText(
        const Connection& _Conn, const std::vector<std::string>& _Args, const std::string& _Input)
    {
        std::vector<std::string> args = GlobalArgs(_Conn, "", _Conn.m_Charset, false);
        args.insert(args.end(), _Args.begin(), _Args.end());
        const platform::ProcessResult process = platform::RunProcess(args, _Conn.m_Dir, _Input);
        CommandResult out;
        out.m_iExitCode = process.m_iExitCode;
        if (!process.m_bStarted)
        {
            out.m_Errors.push_back("Could not run p4: " + process.m_StartError);
            return out;
        }
        out.m_Data = process.m_Output;
        std::string err = process.m_Error;
        while (!err.empty() && (err.back() == '\n' || err.back() == '\r'))
        {
            err.pop_back();
        }
        if (!err.empty())
        {
            out.m_Errors.push_back(err);
        }
        else if (process.m_iExitCode != 0)
        {
            out.m_Errors.push_back(process.m_Output);
        }
        return out;
    }

    CommandResult P4Command::RunOrThrow(const Connection& _Conn,
        const std::vector<std::string>& _Args, const Record& _Input, const PasswordProvider& _Passwords)
    {
        CommandResult result = Run(_Conn, _Args, _Input, _Passwords);
        if (!result.Ok())
        {
            throw git::GitError(result.Message());
        }
        return result;
    }

    bool P4Command::Login(
        const Connection& _Conn, const std::string& _Password, std::string& _OutError)
    {
        Connection conn = _Conn;
        {
            std::lock_guard<std::mutex> lock(g_TicketMutex);
            if (conn.m_Charset.empty() && g_UnicodePorts.count(conn.m_Port) != 0)
            {
                conn.m_Charset = "utf8";
            }
        }
        // -p prints the ticket instead of storing it; -a makes it valid from
        // any address (the same machine may reach the server several ways).
        const CommandResult result = RunText(conn, {"login", "-p", "-a"}, _Password + "\n");
        if (!result.Ok())
        {
            _OutError = result.Message();
            return false;
        }
        // The ticket is the last non-empty line ("Enter password:" and
        // "User x logged in." may come first).
        std::string ticket;
        std::size_t nend = result.m_Data.size();
        while (nend > 0)
        {
            std::size_t nstart = result.m_Data.rfind('\n', nend - 1);
            nstart = nstart == std::string::npos ? 0 : nstart + 1;
            std::string line = result.m_Data.substr(nstart, nend - nstart);
            while (!line.empty() && (line.back() == '\r' || line.back() == ' '))
            {
                line.pop_back();
            }
            if (!line.empty())
            {
                ticket = line;
                break;
            }
            nend = nstart == 0 ? 0 : nstart - 1;
        }
        if (ticket.empty() || ticket.find(' ') != std::string::npos)
        {
            _OutError = ticket.empty() ? std::string("p4 login printed no ticket") : ticket;
            return false;
        }
        std::lock_guard<std::mutex> lock(g_TicketMutex);
        g_Tickets[TicketKey(_Conn)] = ticket;
        return true;
    }

    // ---- helpers -------------------------------------------------------------------

    std::string EscapePath(const std::string& _Path)
    {
        std::string out;
        out.reserve(_Path.size());
        for (const char c : _Path)
        {
            switch (c)
            {
            case '%':
                out += "%25";
                break;
            case '@':
                out += "%40";
                break;
            case '#':
                out += "%23";
                break;
            case '*':
                out += "%2A";
                break;
            default:
                out.push_back(c);
            }
        }
        return out;
    }

    std::string UnescapePath(const std::string& _Path)
    {
        std::string out;
        out.reserve(_Path.size());
        for (std::size_t i = 0; i < _Path.size(); ++i)
        {
            if (_Path[i] == '%' && i + 2 < _Path.size())
            {
                const std::string hex = _Path.substr(i + 1, 2);
                if (hex == "25" || hex == "40" || hex == "23" || hex == "2A" || hex == "2a")
                {
                    out.push_back(static_cast<char>(std::stoi(hex, nullptr, 16)));
                    i += 2;
                    continue;
                }
            }
            out.push_back(_Path[i]);
        }
        return out;
    }

    std::string Field(const Record& _Record, const std::string& _Key, const std::string& _Default)
    {
        const auto it = _Record.find(_Key);
        return it == _Record.end() ? _Default : it->second;
    }

} // namespace gitgud::p4
