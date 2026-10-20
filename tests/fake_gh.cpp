// A stand-in for the GitHub CLI, for tests/ui/signin.lua (GITGUD_TEST_GH
// points views/github.lua at it): the browser sign-in up to its one-time
// code, offline.
//
//   gh --version                     prints a version
//   gh auth login --web ...          prints a one-time code and the device
//                                    page, then waits to be stopped (as the
//                                    real one waits for the browser); exits
//                                    0 after 120 s
//   gh auth token ...                not signed in: exit 1
//   anything else                    exit 2

#include <chrono>
#include <cstdio>
#include <string>
#include <thread>

int main(int _iArgc, char** _aszArgv)
{
    const std::string first = _iArgc > 1 ? _aszArgv[1] : "";
    const std::string second = _iArgc > 2 ? _aszArgv[2] : "";
    if (first == "--version")
    {
        std::printf("gh version 0.0.0-fake (test stand-in)\n");
        return 0;
    }
    if (first == "auth" && second == "token")
    {
        std::fprintf(stderr, "no oauth token found (test stand-in)\n");
        return 1;
    }
    if (first == "auth" && second == "login")
    {
        std::printf("! First copy your one-time code: ABCD-1234\n");
        std::printf("Open this URL to continue in your web browser: https://github.com/login/device\n");
        std::fflush(stdout);
        for (int i = 0; i < 1200; ++i)
        {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
        return 0;
    }
    std::fprintf(stderr, "fake gh: unknown command\n");
    return 2;
}
