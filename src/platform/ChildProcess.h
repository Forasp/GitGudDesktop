#pragma once

// -----------------------------------------------------------------------------
// ChildProcess: a long-lived program the app talks to, such as a Claude Code
// session (`claude -p` with stream-json both ways): write to its stdin at
// any time, read stdout and stderr as lines while it runs, stop it.
//
// Started without a shell (a .cmd or .bat runs through cmd.exe, with
// arguments that can't be misread there). It runs in a job object, so
// Kill() and the destructor end it and everything it started; when it exits
// on its own, whatever it left running is ended too (it would hold the
// output pipes open).
//
// Callbacks run on the process's reader threads, one per stream, so lines
// from one stream arrive in order; OnExit runs once, after both streams are
// drained. Callbacks should only hand their data on (post it to the
// EventBus). From a callback, Wait() doesn't wait (it reports the exit code
// or -1), and destroying the object doesn't join its threads; they finish on
// their own. Windows only for now (other platforms report "not
// implemented").
// -----------------------------------------------------------------------------

#include <functional>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace gitgud::platform
{

    class ChildProcess
    {
      public:
        struct Options
        {
            // The program (found like RunProcess does; "name" also finds
            // name.cmd and name.bat) and its arguments.
            std::vector<std::string> m_Args;
            std::string m_WorkingDir; // "" inherits ours
            // Added to (or replacing in) our environment; an empty value
            // removes the variable.
            std::vector<std::pair<std::string, std::string>> m_Env;
        };

        // One line, without its line break ("\r\n" or "\n"). A last line with
        // no break is delivered when the stream ends.
        using OnLine = std::function<void(const std::string& _Line)>;
        using OnExit = std::function<void(int _iExitCode)>;

        ChildProcess();
        ~ChildProcess(); // kills the process if it still runs, then waits

        ChildProcess(const ChildProcess&) = delete;
        ChildProcess& operator=(const ChildProcess&) = delete;

        // Start it once. Any callback may be empty. False with `_Error` when
        // it can't start.
        bool Start(const Options& _Options, OnLine _OnStdout, OnLine _OnStderr, OnExit _OnExit,
            std::string& _Error);

        // Queue a write to stdin, from any thread; never blocks (a writer
        // thread feeds the pipe in order). False once stdin is closed, a write
        // has failed, or the process has gone.
        bool Write(const std::string& _Data);
        bool WriteLine(const std::string& _Line); // adds "\n"

        // End of input: programs reading stdin see end-of-file once the
        // queued writes are in. Doesn't wait for them.
        void CloseStdin();

        // End the process and everything it started (exit code 137).
        void Kill();

        bool Running() const;

        // Wait up to `_iTimeoutMs` (negative: forever) for the exit and the
        // callbacks. The exit code, or -1 on a timeout or if never started.
        int Wait(int _iTimeoutMs);

        // The process id, 0 before Start.
        unsigned long Id() const;

      private:
        struct Impl;
        std::shared_ptr<Impl> m_pImpl; // shared with its threads
    };

} // namespace gitgud::platform
