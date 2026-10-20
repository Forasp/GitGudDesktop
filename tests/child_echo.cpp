// A test child for ChildProcess: reads commands from stdin, one per line.
//
//   out <text>    print <text> on stdout
//   err <text>    print <text> on stderr
//   env <name>    print the variable's value (or "<unset>") on stdout
//   cwd           print the working folder on stdout
//   big <n>       print one line of <n> 'x' characters on stdout
//   spawn         start another copy of itself that waits forever
//   stall         print "stalled", then stop reading stdin for good
//   exit <code>   exit with <code>
//
// End of input exits with 0. Output is flushed after every command.

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <string>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

int main(int _iArgc, char** _aszArgv)
{
    if (_iArgc > 1 && std::string(_aszArgv[1]) == "--wait")
    {
        for (;;)
        {
            std::getchar(); // blocks until its stdin closes, then spins on EOF
#if defined(_WIN32)
            Sleep(1000);
#endif
        }
    }
    std::string line;
    while (std::getline(std::cin, line))
    {
        if (!line.empty() && line.back() == '\r')
        {
            line.pop_back();
        }
        const std::size_t nspace = line.find(' ');
        const std::string command = line.substr(0, nspace);
        const std::string argument = nspace == std::string::npos ? "" : line.substr(nspace + 1);
        if (command == "out")
        {
            std::cout << argument << "\n" << std::flush;
        }
        else if (command == "err")
        {
            std::cerr << argument << "\n" << std::flush;
        }
        else if (command == "env")
        {
            const char* szvalue = std::getenv(argument.c_str());
            std::cout << (szvalue ? szvalue : "<unset>") << "\n" << std::flush;
        }
        else if (command == "cwd")
        {
            std::cout << std::filesystem::current_path().u8string() << "\n" << std::flush;
        }
        else if (command == "big")
        {
            std::cout << std::string(std::stoul(argument), 'x') << "\n" << std::flush;
        }
        else if (command == "spawn")
        {
#if defined(_WIN32)
            wchar_t szself[MAX_PATH] = {};
            GetModuleFileNameW(nullptr, szself, MAX_PATH);
            std::wstring cmd = L"\"" + std::wstring(szself) + L"\" --wait";
            STARTUPINFOW si = {};
            si.cb = sizeof(si);
            PROCESS_INFORMATION pi = {};
            if (CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, TRUE, CREATE_NO_WINDOW,
                    nullptr, nullptr, &si, &pi))
            {
                std::cout << pi.dwProcessId << "\n" << std::flush;
                CloseHandle(pi.hThread);
                CloseHandle(pi.hProcess);
            }
#endif
        }
        else if (command == "stall")
        {
            std::cout << "stalled\n" << std::flush;
            for (;;) // stops reading stdin until killed
            {
#if defined(_WIN32)
                Sleep(1000);
#endif
            }
        }
        else if (command == "exit")
        {
            return std::atoi(argument.c_str());
        }
    }
    return 0;
}
