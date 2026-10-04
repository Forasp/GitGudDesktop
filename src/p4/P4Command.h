#pragma once

// -----------------------------------------------------------------------------
// P4Command: runs the p4 command-line client and reads what it prints.
//
// Every command runs as `p4 -G ...`: p4 then writes each result as a
// marshalled dictionary (Python marshal, version 0), which is binary-safe and
// carries multi-line fields intact. Specs (client, stream, change, label) go
// back the same way with `-G <spec> -i`.
//
// Connection settings are always passed as flags (-p -u -c -C -d), so the
// user's own P4PORT/P4CLIENT/P4CONFIG never redirect a command. Tickets come
// from the user's p4tickets file as usual, or from an in-process cache filled
// by Login(). BLOCKS: a server round trip per call.
// -----------------------------------------------------------------------------

#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <vector>

namespace gitgud::p4
{

    // One result dictionary ("code" is "stat", "info", "error", "text", ...).
    using Record = std::map<std::string, std::string>;

    // Encode / decode p4's -G wire format.
    std::string MarshalRecord(const Record& _Record);
    // Reads every dictionary in `_Data`; stops at the first malformed byte.
    std::vector<Record> UnmarshalRecords(const std::string& _Data);

    // Where and as whom commands run.
    struct Connection
    {
        std::string m_Port;    // P4PORT, e.g. "ssl:perforce.example.com:1666"
        std::string m_User;    // P4USER
        std::string m_Client;  // P4CLIENT (workspace name); "" for server-only commands
        std::string m_Charset; // P4CHARSET ("" = none; "utf8" for unicode servers)
        std::string m_Dir;     // working directory (-d); usually the workspace root
    };

    // What one command produced, sorted by kind.
    struct CommandResult
    {
        std::vector<Record> m_Stats;         // code "stat"
        std::vector<std::string> m_Info;     // code "info": message lines
        std::vector<std::string> m_Warnings; // code "error", severity <= 2 ("no such file(s)")
        std::vector<std::string> m_Errors;   // code "error", severity >= 3
        std::string m_Data;                  // concatenated "text" / "binary" records (p4 print)
        bool m_bBinary = false;              // m_Data came from "binary" records
        int m_iExitCode = 0;

        bool Ok() const
        {
            return m_Errors.empty();
        }

        // Errors (or, without errors, warnings) joined into one message.
        std::string Message() const;
    };

    // Asks for the password of `_User` on server `_Port`. `_bRejected` is true
    // when the server just refused the previous answer. Return false to give up.
    using PasswordProvider = std::function<bool(const std::string& _Port, const std::string& _User,
        bool _bRejected, std::string& _OutPassword)>;

    class P4Command
    {
      public:
        // Full path of the p4 executable: $GITGUD_P4, else p4 on PATH, else the
        // default install folder. "" when none is found.
        static std::string Executable();

        static bool Available()
        {
            return !Executable().empty();
        }

        // Run `p4 -G <_Args...>`. `_Input` (when not empty) is marshalled to
        // stdin, for `-i` spec commands. Never throws for server errors; see
        // CommandResult::Ok(). Retries once through `_Passwords` (when set) if
        // the server asks for a login.
        static CommandResult Run(const Connection& _Conn, const std::vector<std::string>& _Args,
            const Record& _Input = {}, const PasswordProvider& _Passwords = nullptr);

        // Like Run, but feeds raw text to stdin (p4 login reads the password).
        static CommandResult RunText(const Connection& _Conn, const std::vector<std::string>& _Args,
            const std::string& _Input);

        // Run and throw GitError with the server's message when it failed.
        static CommandResult RunOrThrow(const Connection& _Conn,
            const std::vector<std::string>& _Args, const Record& _Input = {},
            const PasswordProvider& _Passwords = nullptr);

        // `p4 login` with `_Password`; the ticket is kept in memory for this
        // process (never written to disk). Returns false with the server's
        // message in `_OutError` when the password was refused.
        static bool Login(
            const Connection& _Conn, const std::string& _Password, std::string& _OutError);

        // True when the error text means "log in first".
        static bool IsLoginError(const std::string& _Message);

        // Forget the in-memory tickets (tests).
        static void ClearTickets();

      private:
        static std::string TicketFor(const Connection& _Conn);
    };

    // ---- small helpers shared by the backend --------------------------------

    // Escape the characters p4 reads as revision or wildcard syntax
    // (@ # % *) in a file argument.
    std::string EscapePath(const std::string& _Path);
    // Undo EscapePath (p4 prints depot and client paths escaped).
    std::string UnescapePath(const std::string& _Path);

    // Field `_Key` of `_Record`, or `_Default`.
    std::string Field(
        const Record& _Record, const std::string& _Key, const std::string& _Default = "");

} // namespace gitgud::p4
