// -----------------------------------------------------------------------------
// LuaUpdateBindings: checking for, downloading, and installing updates (see
// app/Updater.h). The UI lives in resources/scripts/views/updates.lua.
//
//   gitgud.updateInfo()      -> { current, packaged, staged, downloading, otherCopies }
//   gitgud.updateCheck()     -> true; "update.check.done" detail is tab-separated:
//                               "none\t<latest>" or
//                               "available\t<version>\t<notes url>\t<bytes>\t<files>"
//   gitgud.updateDownload()  -> true; "update.progress" ("<done> <total>" bytes),
//                               then "update.download.done" (version) / ".error"
//   gitgud.updateCancel()    -- stop a download
//   gitgud.updateRestart()   -> true (the caller quits; the patcher takes over) |
//                               nil, message, other-copies count
//   gitgud.updateDiscard()   -- drop a downloaded update
//   gitgud.updateReport()    -> the patcher's report after an update, once, or nil
// -----------------------------------------------------------------------------

#include <atomic>
#include <stdexcept>
#include <string>

#include "app/EventBus.h"
#include "app/TaskRunner.h"
#include "app/Updater.h"
#include "lua/LuaBindings.h"

namespace gitgud::lua::bindings
{

    namespace
    {

        namespace updater = gitgud::app::updater;

        std::atomic<bool> g_bDownloading{false};
        std::atomic<bool> g_bCancel{false};

        int LUpdateInfo(lua_State* _pL)
        {
            lua_newtable(_pL);
            SetField(_pL, "current", updater::CurrentVersion());
            SetField(_pL, "packaged", updater::IsPackagedBuild());
            SetField(_pL, "staged", updater::StagedVersion());
            SetField(_pL, "downloading", g_bDownloading.load());
            SetField(_pL, "otherCopies", static_cast<lua_Integer>(updater::OtherCopies()));
            return 1;
        }

        int LUpdateCheck(lua_State* _pL)
        {
            auto* ptasks = Self(_pL)->TaskRunner();
            if (!ptasks)
            {
                return FailWith(_pL, "no task runner");
            }
            ptasks->Run("update.check",
                []() -> std::string
                {
                    const updater::CheckResult result = updater::Check();
                    if (!result.m_bAvailable)
                    {
                        return "none\t" + result.m_Version;
                    }
                    return "available\t" + result.m_Version + "\t" + result.m_Notes + "\t" +
                           std::to_string(result.m_uDownloadBytes) + "\t" +
                           std::to_string(result.m_nFiles);
                });
            lua_pushboolean(_pL, 1);
            return 1;
        }

        int LUpdateDownload(lua_State* _pL)
        {
            auto* ptasks = Self(_pL)->TaskRunner();
            auto* pbus = Self(_pL)->EventBus();
            if (!ptasks || !pbus)
            {
                return FailWith(_pL, "no task runner");
            }
            if (g_bDownloading.exchange(true))
            {
                return FailWith(_pL, "An update is already downloading");
            }
            g_bCancel = false;
            ptasks->Run("update.download",
                [pbus]() -> std::string
                {
                    struct Done
                    {
                        ~Done()
                        {
                            g_bDownloading = false;
                        }
                    } done;
                    int ilastPercent = -1;
                    return updater::Download(
                        [pbus, &ilastPercent](std::uint64_t _uDone, std::uint64_t _uTotal)
                        {
                            const int ipercent =
                                _uTotal == 0 ? 100 : static_cast<int>(_uDone * 100 / _uTotal);
                            if (ipercent != ilastPercent)
                            {
                                ilastPercent = ipercent;
                                pbus->Publish({"update.progress",
                                    std::to_string(_uDone) + " " + std::to_string(_uTotal)});
                            }
                        },
                        g_bCancel);
                });
            lua_pushboolean(_pL, 1);
            return 1;
        }

        int LUpdateCancel(lua_State*)
        {
            g_bCancel = true;
            return 0;
        }

        int LUpdateRestart(lua_State* _pL)
        {
            if (updater::StagedVersion().empty())
            {
                return FailWith(_pL, "No update is ready to install");
            }
            const int icopies = updater::OtherCopies();
            if (icopies > 0)
            {
                lua_pushnil(_pL);
                lua_pushstring(_pL, "Other copies of GitGud Desktop are open");
                lua_pushinteger(_pL, icopies);
                return 3;
            }
            std::string error;
            if (!updater::StartPatcher(error))
            {
                return FailWith(_pL, error);
            }
            lua_pushboolean(_pL, 1);
            return 1;
        }

        int LUpdateDiscard(lua_State*)
        {
            g_bCancel = true;
            updater::DiscardStaged();
            return 0;
        }

        int LUpdateReport(lua_State* _pL)
        {
            const std::string report = updater::TakePatcherReport();
            if (report.empty())
            {
                lua_pushnil(_pL);
            }
            else
            {
                lua_pushstring(_pL, report.c_str());
            }
            return 1;
        }

    } // namespace

    void AddUpdateBindings(std::vector<luaL_Reg>& _Out)
    {
        _Out.push_back({"updateInfo", LUpdateInfo});
        _Out.push_back({"updateCheck", LUpdateCheck});
        _Out.push_back({"updateDownload", LUpdateDownload});
        _Out.push_back({"updateCancel", LUpdateCancel});
        _Out.push_back({"updateRestart", LUpdateRestart});
        _Out.push_back({"updateDiscard", LUpdateDiscard});
        _Out.push_back({"updateReport", LUpdateReport});
    }

} // namespace gitgud::lua::bindings
