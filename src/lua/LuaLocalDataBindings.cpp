// -----------------------------------------------------------------------------
// LuaLocalDataBindings: the local app data folder (platform/Shell.h,
// LocalDataDirectory: %LOCALAPPDATA%\Gitgud on Windows), for large files the
// app fetches for itself, such as the Bragi interface's voice models. Names
// are relative, with the config folder's rules (letters, digits, - _ . and
// / between parts; no ..).
//
//   gitgud.localDataPath(name?)       -> the folder's path, or name's in it
//   gitgud.localDataInfo(name)        -> nil | { dir, size, mtime }
//   gitgud.localDataList(name)        -> { entry names } (empty if none)
//   gitgud.localDataRead(name)        -> text | nil
//   gitgud.localDataWrite(name, text) -> true | nil, msg (atomic)
//   gitgud.localDataRemove(name)      -> true | nil, msg (folders too)
//   gitgud.localDataMove(from, to)    -> true | nil, msg (to is replaced)
//
// Tasks (TaskRunner: "<name>.done" / "<name>.error"):
//   gitgud.downloadFile(task, { url, file, sha256, size? })
//       -> true | nil, msg. Downloads url (https) to the local data name
//       `file`, through "<file>.part" so a later try carries on where this
//       one stopped; checks the size and SHA-256, then renames. Publishes
//       "<task>.progress" ({phase = "download"|"verify", done, total}) a few
//       times a second; done carries the file's path. A file whose checksum
//       is wrong is deleted.
//   gitgud.downloadCancel(task)       stop it, or any task below (what
//                                     arrived is kept; a partial copy or
//                                     unpack is removed); its error is
//                                     "cancelled"
//   gitgud.fileSha256(task, path)     done carries the SHA-256 of the file at
//                                     path (anywhere: install from a folder);
//                                     progress {phase = "verify", done, total}
//   gitgud.copyToLocalData(task, path, name)
//                                     copy the file at path to name;
//                                     progress {phase = "copy", done, total}
//   gitgud.extractArchive(task, path, name)
//                                     unpack the archive at path (.zip,
//                                     .tar.bz2, ...) into the folder name,
//                                     emptied first; progress {phase =
//                                     "unpack", done, total}: the bytes of
//                                     the archive the unpacker has read
// -----------------------------------------------------------------------------

#include <algorithm>
#include <atomic>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include "app/EventBus.h"
#include "app/Json.h"
#include "app/TaskRunner.h"
#include "lua/LuaBindings.h"
#include "platform/Http.h"
#include "platform/Shell.h"

namespace gitgud::lua::bindings
{

    namespace
    {

        namespace fs = std::filesystem;
        using app::Json;

        std::mutex g_CancelMutex;
        std::map<std::string, std::shared_ptr<std::atomic<bool>>> g_Cancels;

        fs::path Root()
        {
            return fs::u8path(platform::LocalDataDirectory());
        }

        fs::path CheckedName(lua_State* _pL, int _iArg)
        {
            const char* szname = luaL_checkstring(_pL, _iArg);
            luaL_argcheck(_pL, IsConfigName(szname), _iArg, "invalid local data name");
            return (Root() / fs::u8path(szname)).make_preferred();
        }

        std::shared_ptr<std::atomic<bool>> CancelFlag(const std::string& _Task)
        {
            std::lock_guard<std::mutex> lock(g_CancelMutex);
            auto pflag = std::make_shared<std::atomic<bool>>(false);
            g_Cancels[_Task] = pflag;
            return pflag;
        }

        void DropCancelFlag(
            const std::string& _Task, const std::shared_ptr<std::atomic<bool>>& _pFlag)
        {
            std::lock_guard<std::mutex> lock(g_CancelMutex);
            auto it = g_Cancels.find(_Task);
            if (it != g_Cancels.end() && it->second == _pFlag)
            {
                g_Cancels.erase(it);
            }
        }

        // Progress events, at most every 200 ms (and the last one).
        class Progress
        {
          public:
            Progress(app::EventBus* _pBus, std::string _Task)
                : m_pBus(_pBus), m_Task(std::move(_Task))
            {
            }

            void Report(const char* _szPhase, std::uint64_t _uDone, std::uint64_t _uTotal,
                bool _bForce = false)
            {
                const auto now = std::chrono::steady_clock::now();
                if (!m_pBus || (!_bForce && now - m_Last < std::chrono::milliseconds(200)))
                {
                    return;
                }
                m_Last = now;
                m_pBus->Publish(
                    {m_Task + ".progress", Json::Object()
                                               .Set("phase", _szPhase)
                                               .Set("done", static_cast<double>(_uDone))
                                               .Set("total", static_cast<double>(_uTotal))
                                               .Dump()});
            }

          private:
            app::EventBus* m_pBus;
            std::string m_Task;
            std::chrono::steady_clock::time_point m_Last;
        };

        int Ok(lua_State* _pL)
        {
            lua_pushboolean(_pL, 1);
            return 1;
        }

        int LLocalDataPath(lua_State* _pL)
        {
            const fs::path path = lua_isnoneornil(_pL, 1) ? Root() : CheckedName(_pL, 1);
            const std::string text = fs::path(path).make_preferred().u8string();
            lua_pushlstring(_pL, text.data(), text.size());
            return 1;
        }

        int LLocalDataInfo(lua_State* _pL)
        {
            const fs::path path = CheckedName(_pL, 1);
            std::error_code ec;
            const fs::file_status status = fs::status(path, ec);
            if (ec || !fs::exists(status))
            {
                lua_pushnil(_pL);
                return 1;
            }
            lua_newtable(_pL);
            const bool bdir = fs::is_directory(status);
            SetField(_pL, "dir", bdir);
            SetField(_pL, "size", static_cast<lua_Integer>(bdir ? 0 : fs::file_size(path, ec)));
            const auto mtime = fs::last_write_time(path, ec).time_since_epoch().count();
            SetField(_pL, "mtime", static_cast<lua_Integer>(mtime));
            return 1;
        }

        int LLocalDataList(lua_State* _pL)
        {
            const fs::path path = CheckedName(_pL, 1);
            std::vector<std::string> names;
            std::error_code ec;
            for (fs::directory_iterator it(path, ec), end; !ec && it != end; it.increment(ec))
            {
                names.push_back(it->path().filename().u8string());
            }
            std::sort(names.begin(), names.end());
            PushStringArray(_pL, names);
            return 1;
        }

        int LLocalDataRead(lua_State* _pL)
        {
            const fs::path path = CheckedName(_pL, 1);
            std::ifstream in(path, std::ios::binary);
            if (!in)
            {
                lua_pushnil(_pL);
                return 1;
            }
            std::ostringstream ss;
            ss << in.rdbuf();
            const std::string text = ss.str();
            lua_pushlstring(_pL, text.data(), text.size());
            return 1;
        }

        int LLocalDataWrite(lua_State* _pL)
        {
            const fs::path path = CheckedName(_pL, 1);
            std::size_t nlength = 0;
            const char* sztext = luaL_checklstring(_pL, 2, &nlength);
            std::string error;
            if (!platform::WriteFileAtomically(
                    path.u8string(), std::string(sztext, nlength), error))
            {
                return FailWith(_pL, error);
            }
            return Ok(_pL);
        }

        int LLocalDataRemove(lua_State* _pL)
        {
            const fs::path path = CheckedName(_pL, 1);
            std::error_code ec;
            fs::remove_all(path, ec);
            if (ec)
            {
                return FailWith(_pL, "could not remove " + path.u8string() + ": " + ec.message());
            }
            return Ok(_pL);
        }

        int LLocalDataMove(lua_State* _pL)
        {
            const fs::path from = CheckedName(_pL, 1);
            const fs::path to = CheckedName(_pL, 2);
            std::error_code ec;
            if (!fs::exists(from, ec))
            {
                return FailWith(_pL, "nothing at " + from.u8string());
            }
            fs::create_directories(to.parent_path(), ec);
            fs::remove_all(to, ec);
            fs::rename(from, to, ec);
            if (ec)
            {
                return FailWith(_pL, "could not move " + from.u8string() + ": " + ec.message());
            }
            return Ok(_pL);
        }

        int LDownloadFile(lua_State* _pL)
        {
            const std::string task = luaL_checkstring(_pL, 1);
            luaL_checktype(_pL, 2, LUA_TTABLE);
            auto field = [_pL](const char* _szKey)
            {
                lua_getfield(_pL, 2, _szKey);
                const char* szvalue = lua_tostring(_pL, -1);
                std::string value = szvalue ? szvalue : "";
                lua_pop(_pL, 1);
                return value;
            };
            const std::string url = field("url");
            const std::string file = field("file");
            std::string sha256 = field("sha256");
            lua_getfield(_pL, 2, "size");
            const std::uint64_t usize =
                lua_isinteger(_pL, -1) ? static_cast<std::uint64_t>(lua_tointeger(_pL, -1)) : 0;
            lua_pop(_pL, 1);
            std::transform(sha256.begin(), sha256.end(), sha256.begin(),
                [](unsigned char _C) { return static_cast<char>(std::tolower(_C)); });
            if (url.rfind("https://", 0) != 0)
            {
                return FailWith(_pL, "only https:// URLs are allowed");
            }
            if (!IsConfigName(file.c_str()))
            {
                return FailWith(_pL, "invalid local data name: " + file);
            }
            if (sha256.size() != 64 ||
                sha256.find_first_not_of("0123456789abcdef") != std::string::npos)
            {
                return FailWith(_pL, "a SHA-256 checksum is required");
            }
            auto* ptasks = Self(_pL)->TaskRunner();
            if (!ptasks)
            {
                return FailWith(_pL, "no task runner");
            }
            app::EventBus* pbus = Self(_pL)->EventBus();
            const fs::path target = Root() / fs::u8path(file);
            auto pcancel = CancelFlag(task);
            ptasks->Run(task,
                [task, url, target, sha256, usize, pbus, pcancel]() -> std::string
                {
                    struct Done
                    {
                        std::string m_Task;
                        std::shared_ptr<std::atomic<bool>> m_pFlag;
                        ~Done()
                        {
                            DropCancelFlag(m_Task, m_pFlag);
                        }
                    } done{task, pcancel};
                    Progress progress(pbus, task);
                    const fs::path part = fs::u8path(target.u8string() + ".part");
                    std::string error;
                    const bool bok = platform::HttpDownloadFile(
                        url, part.u8string(),
                        [&](std::uint64_t _uDone, std::uint64_t _uTotal)
                        {
                            progress.Report("download", _uDone, _uTotal ? _uTotal : usize);
                            return !pcancel->load();
                        },
                        error);
                    if (!bok)
                    {
                        throw std::runtime_error(
                            pcancel->load() ? std::string("cancelled") : error);
                    }
                    std::error_code ec;
                    const std::uintmax_t ugot = fs::file_size(part, ec);
                    progress.Report("download", ugot, ugot, true);
                    if (usize && ugot != usize)
                    {
                        if (ugot > usize)
                        {
                            fs::remove(part, ec);
                        }
                        throw std::runtime_error("the download is " + std::to_string(ugot) +
                                                 " bytes, not " + std::to_string(usize));
                    }
                    const std::string sha = platform::Sha256FileHex(part.u8string(),
                        [&](std::uint64_t _uDone)
                        {
                            progress.Report("verify", _uDone, ugot);
                            return !pcancel->load();
                        });
                    if (pcancel->load())
                    {
                        throw std::runtime_error("cancelled");
                    }
                    if (sha != sha256)
                    {
                        fs::remove(part, ec);
                        throw std::runtime_error(
                            "the download didn't match its published checksum");
                    }
                    fs::remove(target, ec);
                    fs::rename(part, target, ec);
                    if (ec)
                    {
                        throw std::runtime_error(
                            "could not finish " + target.u8string() + ": " + ec.message());
                    }
                    return target.u8string();
                });
            return Ok(_pL);
        }

        int LDownloadCancel(lua_State* _pL)
        {
            const std::string task = luaL_checkstring(_pL, 1);
            std::lock_guard<std::mutex> lock(g_CancelMutex);
            auto it = g_Cancels.find(task);
            if (it != g_Cancels.end())
            {
                it->second->store(true);
            }
            return 0;
        }

        // Drops a task's cancel flag when the task ends.
        struct CancelScope
        {
            std::string m_Task;
            std::shared_ptr<std::atomic<bool>> m_pFlag;
            ~CancelScope()
            {
                DropCancelFlag(m_Task, m_pFlag);
            }
        };

        int LFileSha256(lua_State* _pL)
        {
            const std::string task = luaL_checkstring(_pL, 1);
            const std::string path = luaL_checkstring(_pL, 2);
            auto* ptasks = Self(_pL)->TaskRunner();
            if (!ptasks)
            {
                return FailWith(_pL, "no task runner");
            }
            app::EventBus* pbus = Self(_pL)->EventBus();
            auto pcancel = CancelFlag(task);
            ptasks->Run(task,
                [task, path, pbus, pcancel]() -> std::string
                {
                    CancelScope scope{task, pcancel};
                    Progress progress(pbus, task);
                    std::error_code ec;
                    const std::uintmax_t usize = fs::file_size(fs::u8path(path), ec);
                    if (ec)
                    {
                        throw std::runtime_error("cannot read " + path);
                    }
                    const std::string sha = platform::Sha256FileHex(path,
                        [&](std::uint64_t _uDone)
                        {
                            progress.Report("verify", _uDone, usize);
                            return !pcancel->load();
                        });
                    if (pcancel->load())
                    {
                        throw std::runtime_error("cancelled");
                    }
                    progress.Report("verify", usize, usize, true);
                    if (sha.empty())
                    {
                        throw std::runtime_error("cannot read " + path);
                    }
                    return sha;
                });
            return Ok(_pL);
        }

        int LCopyToLocalData(lua_State* _pL)
        {
            const std::string task = luaL_checkstring(_pL, 1);
            const std::string source = luaL_checkstring(_pL, 2);
            const fs::path target = CheckedName(_pL, 3);
            auto* ptasks = Self(_pL)->TaskRunner();
            if (!ptasks)
            {
                return FailWith(_pL, "no task runner");
            }
            app::EventBus* pbus = Self(_pL)->EventBus();
            auto pcancel = CancelFlag(task);
            ptasks->Run(task,
                [task, source, target, pbus, pcancel]() -> std::string
                {
                    CancelScope scope{task, pcancel};
                    Progress progress(pbus, task);
                    std::error_code ec;
                    fs::create_directories(target.parent_path(), ec);
                    const std::uintmax_t utotal = fs::file_size(fs::u8path(source), ec);
                    std::ifstream in(fs::u8path(source), std::ios::binary);
                    if (ec || !in)
                    {
                        throw std::runtime_error("cannot read " + source);
                    }
                    const fs::path part = fs::u8path(target.u8string() + ".part");
                    bool bok = true;
                    {
                        std::ofstream out(part, std::ios::binary | std::ios::trunc);
                        std::vector<char> buffer(8u << 20);
                        std::uint64_t udone = 0;
                        while (out && in)
                        {
                            in.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
                            const std::streamsize ngot = in.gcount();
                            if (ngot <= 0)
                            {
                                break;
                            }
                            out.write(buffer.data(), ngot);
                            udone += static_cast<std::uint64_t>(ngot);
                            progress.Report("copy", udone, utotal);
                            if (pcancel->load())
                            {
                                break;
                            }
                        }
                        bok = static_cast<bool>(out) && udone == utotal;
                    }
                    if (pcancel->load() || !bok)
                    {
                        fs::remove(part, ec);
                        throw std::runtime_error(
                            pcancel->load() ? std::string("cancelled") : "could not copy " + source);
                    }
                    progress.Report("copy", utotal, utotal, true);
                    fs::remove(target, ec);
                    fs::rename(part, target, ec);
                    if (ec)
                    {
                        throw std::runtime_error("could not copy " + source + ": " + ec.message());
                    }
                    return target.u8string();
                });
            return Ok(_pL);
        }

        int LExtractArchive(lua_State* _pL)
        {
            const std::string task = luaL_checkstring(_pL, 1);
            const std::string archive = luaL_checkstring(_pL, 2);
            const fs::path target = CheckedName(_pL, 3);
            auto* ptasks = Self(_pL)->TaskRunner();
            if (!ptasks)
            {
                return FailWith(_pL, "no task runner");
            }
            app::EventBus* pbus = Self(_pL)->EventBus();
            auto pcancel = CancelFlag(task);
            ptasks->Run(task,
                [task, archive, target, pbus, pcancel]() -> std::string
                {
                    CancelScope scope{task, pcancel};
                    Progress progress(pbus, task);
                    std::error_code ec;
                    fs::remove_all(target, ec);
                    std::string error;
                    const bool bok = platform::ExtractArchive(archive, target.u8string(),
                        [&](std::uint64_t _uDone, std::uint64_t _uTotal)
                        {
                            progress.Report("unpack", _uDone, _uTotal, _uDone == _uTotal);
                            return !pcancel->load();
                        },
                        error);
                    if (!bok)
                    {
                        fs::remove_all(target, ec); // nothing half unpacked stays
                        throw std::runtime_error(pcancel->load() ? std::string("cancelled") : error);
                    }
                    return target.u8string();
                });
            return Ok(_pL);
        }

    } // namespace

    void AddLocalDataBindings(std::vector<luaL_Reg>& _Out)
    {
        _Out.push_back({"localDataPath", LLocalDataPath});
        _Out.push_back({"localDataInfo", LLocalDataInfo});
        _Out.push_back({"localDataList", LLocalDataList});
        _Out.push_back({"localDataRead", LLocalDataRead});
        _Out.push_back({"localDataWrite", LLocalDataWrite});
        _Out.push_back({"localDataRemove", LLocalDataRemove});
        _Out.push_back({"localDataMove", LLocalDataMove});
        _Out.push_back({"downloadFile", LDownloadFile});
        _Out.push_back({"downloadCancel", LDownloadCancel});
        _Out.push_back({"fileSha256", LFileSha256});
        _Out.push_back({"copyToLocalData", LCopyToLocalData});
        _Out.push_back({"extractArchive", LExtractArchive});
    }

} // namespace gitgud::lua::bindings
