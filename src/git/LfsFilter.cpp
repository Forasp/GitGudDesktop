// -----------------------------------------------------------------------------
// LfsFilter — Git LFS support for everything libgit2 reads or writes.
//
// Files that .gitattributes marks `filter=lfs` are stored in Git as small
// pointer files; the real content lives in .git/lfs and on the LFS server.
// The git CLI converts between the two by running `git-lfs clean` (working
// tree -> pointer, when staging) and `git-lfs smudge` (pointer -> content, on
// checkout). libgit2 doesn't know about LFS, so without this filter staging an
// LFS file would commit the whole binary. Registering an "lfs" filter that
// pipes through the same git-lfs commands makes libgit2 behave like git.
//
// When git-lfs isn't installed nothing is registered: pointer files are then
// staged and checked out as they are (the UI tells the user LFS is missing).
// -----------------------------------------------------------------------------

#include "git/LibGit2Internal.h"

#include "platform/Process.h"

#include <git2/sys/errors.h>
#include <git2/sys/filter.h>

#include <atomic>
#include <mutex>

namespace gitgud::git::internal
{

    namespace
    {

        std::mutex g_Mutex;
        std::string g_LfsProgram; // git-lfs.exe path, or "" when missing
        bool g_bProbed = false;
        std::atomic<bool> g_bRegistered{false};
        git_filter g_Filter;

        // Collects everything written to it, then runs git-lfs over the whole
        // content when closed and passes the result down the chain.
        struct LfsStream
        {
            git_writestream m_Base; // must stay first: libgit2 sees a git_writestream*
            git_writestream* m_pNext = nullptr;
            std::string m_Buffer;
            std::string m_Path;
            std::string m_WorkDir;
            bool m_bClean = true; // true: to the object database; false: to the working tree
        };

        int StreamWrite(git_writestream* _pStream, const char* _pBuffer, size_t _nLength)
        {
            auto* pself = reinterpret_cast<LfsStream*>(_pStream);
            pself->m_Buffer.append(_pBuffer, _nLength);
            return 0;
        }

        int StreamClose(git_writestream* _pStream)
        {
            auto* pself = reinterpret_cast<LfsStream*>(_pStream);
            const std::string program = g_LfsProgram;
            const platform::ProcessResult result = platform::RunProcess(
                {program, pself->m_bClean ? "clean" : "smudge", "--", pself->m_Path},
                pself->m_WorkDir, pself->m_Buffer);

            const std::string* pout = &result.m_Output;
            if (!result.m_bStarted || result.m_iExitCode != 0)
            {
                if (pself->m_bClean)
                {
                    // Never fall back to committing the raw file: that is
                    // exactly what LFS is there to prevent.
                    std::string message = "git-lfs clean failed for '" + pself->m_Path + "'";
                    if (!result.m_Error.empty())
                    {
                        message += ": " + result.m_Error;
                    }
                    git_error_set_str(GIT_ERROR_FILTER, message.c_str());
                    return -1;
                }
                // Checkout without the object (offline, not fetched yet): keep
                // the pointer file so the checkout itself still succeeds.
                pout = &pself->m_Buffer;
            }

            const int iwrite = pself->m_pNext->write(pself->m_pNext, pout->data(), pout->size());
            if (iwrite < 0)
            {
                return iwrite;
            }
            return pself->m_pNext->close(pself->m_pNext);
        }

        void StreamFree(git_writestream* _pStream)
        {
            delete reinterpret_cast<LfsStream*>(_pStream);
        }

        int FilterStream(git_writestream** _ppOut, git_filter*, void**,
            const git_filter_source* _pSource, git_writestream* _pNext)
        {
            auto* pstream = new LfsStream();
            pstream->m_Base.write = StreamWrite;
            pstream->m_Base.close = StreamClose;
            pstream->m_Base.free = StreamFree;
            pstream->m_pNext = _pNext;
            pstream->m_bClean = git_filter_source_mode(_pSource) == GIT_FILTER_TO_ODB;
            if (const char* szpath = git_filter_source_path(_pSource))
            {
                pstream->m_Path = szpath;
            }
            if (git_repository* prepo = git_filter_source_repo(_pSource))
            {
                const char* szworkdir = git_repository_workdir(prepo);
                pstream->m_WorkDir = szworkdir ? szworkdir : git_repository_path(prepo);
            }
            *_ppOut = &pstream->m_Base;
            return 0;
        }

    } // namespace

    void RegisterLfsFilter()
    {
        std::lock_guard<std::mutex> lock(g_Mutex);
        if (!g_bProbed)
        {
            g_bProbed = true;
            g_LfsProgram = platform::FindProgram("git-lfs");
        }
        if (g_LfsProgram.empty())
        {
            return;
        }

        // libgit2 forgets registrations when its last user shuts down, so
        // this runs after every init; "already registered" is fine.
        static bool bfilterReady = false;
        if (!bfilterReady)
        {
            bfilterReady = true;
            git_filter_init(&g_Filter, GIT_FILTER_VERSION);
            g_Filter.attributes = "filter=lfs";
            g_Filter.stream = FilterStream;
        }
        const int irc = git_filter_register("lfs", &g_Filter, GIT_FILTER_DRIVER_PRIORITY);
        if (irc == 0 || irc == GIT_EEXISTS)
        {
            g_bRegistered = true;
        }
    }

    bool LfsFilterRegistered()
    {
        return g_bRegistered.load();
    }

} // namespace gitgud::git::internal

namespace gitgud::git
{

    bool Repository::LfsAvailable()
    {
        return internal::LfsFilterRegistered();
    }

} // namespace gitgud::git
