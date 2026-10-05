#pragma once

// -----------------------------------------------------------------------------
// Process — run external programs and capture what they print.
//
// Used where Git work is delegated to the tools the user already has: commit
// signing (gpg / ssh-keygen), Git LFS (git-lfs clean/smudge), SSH key
// generation, and the built-in console pane. Everything is synchronous and
// BLOCKS; callers on the UI thread keep inputs small (signing a commit) and
// anything long (the console) runs on a TaskRunner worker.
//
// Windows uses CreateProcess and cmd.exe; macOS and Linux use fork/exec and
// /bin/sh.
// -----------------------------------------------------------------------------

#include <atomic>
#include <functional>
#include <string>
#include <vector>

namespace gitgud::platform
{

    struct ProcessResult
    {
        bool m_bStarted = false; // false: the program could not be launched
        int m_iExitCode = -1;
        std::string m_Output;     // everything written to stdout
        std::string m_Error;      // everything written to stderr
        std::string m_StartError; // why it didn't start (m_bStarted == false)
    };

    // Run `_Args[0]` with the remaining arguments (each quoted as needed),
    // feed `_Input` to its stdin, and wait for it to exit. `_WorkingDir` ""
    // inherits the current directory. The program is found like a shell would
    // (full path, or a name searched on PATH; ".exe" may be omitted).
    ProcessResult RunProcess(const std::vector<std::string>& _Args, const std::string& _WorkingDir,
        const std::string& _Input = "");

    // Run a whole command line through the system shell (cmd.exe /c, or
    // /bin/sh -c outside Windows), merging
    // stdout and stderr and handing each chunk to `_OnOutput` as it arrives.
    // Setting `*_pCancel` to true kills the command and everything it started.
    // Returns the exit code (-1 when it couldn't start or was cancelled).
    int RunShellStreaming(const std::string& _CommandLine, const std::string& _WorkingDir,
        const std::function<void(const std::string&)>& _OnOutput, std::atomic<bool>* _pCancel);

    // Run `_Args[0]` (found like RunProcess does) with the remaining
    // arguments, without a shell and with no stdin, streaming its merged
    // output like RunShellStreaming. Same cancel and return rules.
    int RunProcessStreaming(const std::vector<std::string>& _Args, const std::string& _WorkingDir,
        const std::function<void(const std::string&)>& _OnOutput, std::atomic<bool>* _pCancel);

    // Full path of a program on PATH (or in Git for Windows' install folders,
    // which carry gpg and git-lfs), or "" when it can't be found.
    std::string FindProgram(const std::string& _Name);

    // Quote one argument for a Windows command line (CommandLineToArgvW rules).
    std::string QuoteArgument(const std::string& _Arg);

} // namespace gitgud::platform
