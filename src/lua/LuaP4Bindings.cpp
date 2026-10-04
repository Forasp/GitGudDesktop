// -----------------------------------------------------------------------------
// LuaP4Bindings: the Perforce half of the `gitgud` table.
//
//   * gitgud.backend() / gitgud.supports(feature): which backend the open
//     repository uses and what it can do, so the interfaces hide commands a
//     backend doesn't have.
//   * gitgud.p4*: server-side changelists and file state for the Depot
//     interface (check out, reopen, submit a selection, shelve...), and the
//     setup calls that list streams/depots/workspaces and create a workspace.
//
// Same conventions as LuaRepoBindings (docs/LUA_API.md): sync actions return
// a value or (nil, message) and publish "status.changed"; calls that only
// need the server run on a worker and answer with "<op>.done/.error".
// -----------------------------------------------------------------------------

#include "lua/LuaBindings.h"

#include "app/EventBus.h"
#include "app/TaskRunner.h"
#include "git/Repository.h"
#include "p4/P4Workspace.h"

#include <string>
#include <vector>

namespace gitgud::lua::bindings
{

    namespace
    {

        using gitgud::git::GitError;
        using gitgud::p4::P4Workspace;

        void Changed(LuaEngine* _pEngine)
        {
            if (auto* pbus = _pEngine->EventBus())
            {
                pbus->Publish({"status.changed", ""});
            }
        }

        // Run `_Fn(workspace)` with the (nil, message) convention. `_Fn`
        // pushes its results and returns how many.
        template <typename Fn> int P4Call(lua_State* _pL, bool _bMutates, Fn&& _Fn)
        {
            LuaEngine* pengine = Self(_pL);
            auto* prepo = pengine->Repository();
            if (!prepo || !prepo->IsOpen())
            {
                return NoRepo(_pL);
            }
            P4Workspace* pws = prepo->P4();
            if (!pws)
            {
                return FailWith(_pL, "This repository is not a Perforce workspace");
            }
            const int itop = lua_gettop(_pL);
            try
            {
                const int iresults = _Fn(*pws);
                if (_bMutates)
                {
                    Changed(pengine);
                }
                return iresults;
            }
            catch (const GitError& e)
            {
                lua_settop(_pL, itop);
                return FailWith(_pL, e.what());
            }
        }

        std::string OptString(lua_State* _pL, int _iArg, const char* _szDefault)
        {
            return lua_isnoneornil(_pL, _iArg) ? std::string(_szDefault)
                                               : std::string(luaL_checkstring(_pL, _iArg));
        }

        std::vector<std::string> OptList(lua_State* _pL, int _iArg)
        {
            return lua_isnoneornil(_pL, _iArg) ? std::vector<std::string>()
                                               : StringList(_pL, _iArg);
        }

        // {port, user, charset} -> Connection (no workspace).
        gitgud::p4::Connection ConnectionArg(lua_State* _pL, int _iArg)
        {
            luaL_checktype(_pL, _iArg, LUA_TTABLE);
            gitgud::p4::Connection conn;
            const auto field = [&](const char* _szKey)
            {
                lua_getfield(_pL, _iArg, _szKey);
                std::string v = lua_type(_pL, -1) == LUA_TSTRING ? lua_tostring(_pL, -1) : "";
                lua_pop(_pL, 1);
                return v;
            };
            conn.m_Port = field("port");
            conn.m_User = field("user");
            conn.m_Charset = field("charset");
            return conn;
        }

        // ---- backend -----------------------------------------------------------------

        // gitgud.backend() -> "git" | "p4" | "" (nothing open)
        int LBackend(lua_State* _pL)
        {
            auto* prepo = Self(_pL)->Repository();
            const std::string backend = prepo && prepo->IsOpen() ? prepo->Backend() : std::string();
            lua_pushlstring(_pL, backend.data(), backend.size());
            return 1;
        }

        // gitgud.supports(feature) -> bool (see Repository::Supports)
        int LSupports(lua_State* _pL)
        {
            const std::string feature = luaL_checkstring(_pL, 1);
            auto* prepo = Self(_pL)->Repository();
            lua_pushboolean(_pL,
                prepo && prepo->IsOpen() ? prepo->Supports(feature) : feature != "changelists");
            return 1;
        }

        // gitgud.p4Available() -> bool, path of p4.exe
        int LP4Available(lua_State* _pL)
        {
            const std::string exe = gitgud::p4::P4Command::Executable();
            lua_pushboolean(_pL, !exe.empty());
            lua_pushlstring(_pL, exe.data(), exe.size());
            return 2;
        }

        // gitgud.p4Info() -> {userName, clientName, clientStream, serverAddress, serverVersion,
        // ...}
        int LP4Info(lua_State* _pL)
        {
            return P4Call(_pL, false,
                [&](P4Workspace& _Ws)
                {
                    const gitgud::p4::Record info = _Ws.Info();
                    lua_newtable(_pL);
                    for (const auto& [key, value] : info)
                    {
                        SetField(_pL, key.c_str(), value);
                    }
                    SetField(_pL, "port", _Ws.Conn().m_Port);
                    SetField(_pL, "streams", _Ws.UsesStreams());
                    return 1;
                });
        }

        // ---- changelists --------------------------------------------------------------

        // gitgud.p4Changes() -> {{change, description, user, time,
        //   files = {{path, depotFile, action, type, rev, unresolved, locked}},
        //   shelved = {{path, depotFile, action}}}}  (default first)
        int LP4Changes(lua_State* _pL)
        {
            return P4Call(_pL, false,
                [&](P4Workspace& _Ws)
                {
                    const auto changes = _Ws.PendingChanges();
                    lua_createtable(_pL, static_cast<int>(changes.size()), 0);
                    int i = 1;
                    for (const auto& c : changes)
                    {
                        lua_createtable(_pL, 0, 6);
                        SetField(_pL, "change", c.m_Change);
                        SetField(_pL, "description", c.m_Description);
                        SetField(_pL, "user", c.m_User);
                        SetField(_pL, "time", static_cast<lua_Integer>(c.m_TimeUtc));
                        lua_createtable(_pL, static_cast<int>(c.m_Files.size()), 0);
                        int j = 1;
                        for (const auto& f : c.m_Files)
                        {
                            lua_createtable(_pL, 0, 7);
                            SetField(_pL, "path", f.m_Path);
                            SetField(_pL, "depotFile", f.m_DepotFile);
                            SetField(_pL, "action", f.m_Action);
                            SetField(_pL, "type", f.m_Type);
                            SetField(_pL, "rev", static_cast<lua_Integer>(f.m_iRev));
                            SetField(_pL, "unresolved", f.m_bUnresolved);
                            SetField(_pL, "locked", f.m_bLocked);
                            lua_rawseti(_pL, -2, j++);
                        }
                        lua_setfield(_pL, -2, "files");
                        lua_createtable(_pL, static_cast<int>(c.m_Shelved.size()), 0);
                        j = 1;
                        for (const auto& f : c.m_Shelved)
                        {
                            lua_createtable(_pL, 0, 3);
                            SetField(_pL, "path", f.m_Path);
                            SetField(_pL, "depotFile", f.m_DepotFile);
                            SetField(_pL, "action", f.m_Action);
                            lua_rawseti(_pL, -2, j++);
                        }
                        lua_setfield(_pL, -2, "shelved");
                        lua_rawseti(_pL, -2, i++);
                    }
                    return 1;
                });
        }

        // gitgud.p4NewChange(description, paths?) -> change number
        int LP4NewChange(lua_State* _pL)
        {
            const std::string desc = luaL_checkstring(_pL, 1);
            const std::vector<std::string> paths = OptList(_pL, 2);
            return P4Call(_pL, true,
                [&](P4Workspace& _Ws)
                {
                    const std::string change = _Ws.CreateChange(desc, paths);
                    lua_pushlstring(_pL, change.data(), change.size());
                    return 1;
                });
        }

        // gitgud.p4SetDescription(change, description)
        int LP4SetDescription(lua_State* _pL)
        {
            const std::string change = luaL_checkstring(_pL, 1);
            const std::string desc = luaL_checkstring(_pL, 2);
            return P4Call(_pL, true,
                [&](P4Workspace& _Ws)
                {
                    _Ws.SetChangeDescription(change, desc);
                    lua_pushboolean(_pL, 1);
                    return 1;
                });
        }

        // gitgud.p4DeleteChange(change)
        int LP4DeleteChange(lua_State* _pL)
        {
            const std::string change = luaL_checkstring(_pL, 1);
            return P4Call(_pL, true,
                [&](P4Workspace& _Ws)
                {
                    _Ws.DeleteChange(change);
                    lua_pushboolean(_pL, 1);
                    return 1;
                });
        }

        // Shared shape of gitgud.p4Reopen/p4Edit/p4Add/p4Delete(paths, change?).
        template <typename Fn> int PathsAndChange(lua_State* _pL, Fn&& _Fn)
        {
            const std::vector<std::string> paths = StringList(_pL, 1);
            const std::string change = OptString(_pL, 2, "default");
            return P4Call(_pL, true,
                [&](P4Workspace& _Ws)
                {
                    _Fn(_Ws, paths, change);
                    lua_pushboolean(_pL, 1);
                    return 1;
                });
        }

        int LP4Reopen(lua_State* _pL)
        {
            return PathsAndChange(
                _pL, [](P4Workspace& _Ws, const auto& _P, const auto& _C) { _Ws.Reopen(_P, _C); });
        }

        int LP4Edit(lua_State* _pL)
        {
            return PathsAndChange(
                _pL, [](P4Workspace& _Ws, const auto& _P, const auto& _C) { _Ws.Edit(_P, _C); });
        }

        int LP4Add(lua_State* _pL)
        {
            return PathsAndChange(
                _pL, [](P4Workspace& _Ws, const auto& _P, const auto& _C) { _Ws.Add(_P, _C); });
        }

        int LP4Delete(lua_State* _pL)
        {
            return PathsAndChange(
                _pL, [](P4Workspace& _Ws, const auto& _P, const auto& _C) { _Ws.Delete(_P, _C); });
        }

        // gitgud.p4Move(from, to, change?)
        int LP4Move(lua_State* _pL)
        {
            const std::string from = luaL_checkstring(_pL, 1);
            const std::string to = luaL_checkstring(_pL, 2);
            const std::string change = OptString(_pL, 3, "default");
            return P4Call(_pL, true,
                [&](P4Workspace& _Ws)
                {
                    _Ws.Move(from, to, change);
                    lua_pushboolean(_pL, 1);
                    return 1;
                });
        }

        // gitgud.p4Revert(paths, keepLocal?)
        int LP4Revert(lua_State* _pL)
        {
            const std::vector<std::string> paths = StringList(_pL, 1);
            const bool bkeep = lua_toboolean(_pL, 2) != 0;
            return P4Call(_pL, true,
                [&](P4Workspace& _Ws)
                {
                    _Ws.RevertFiles(paths, bkeep);
                    lua_pushboolean(_pL, 1);
                    return 1;
                });
        }

        // gitgud.p4RevertUnchanged(change?) -> reverted paths
        int LP4RevertUnchanged(lua_State* _pL)
        {
            const std::string change = OptString(_pL, 1, "");
            return P4Call(_pL, true,
                [&](P4Workspace& _Ws)
                {
                    PushStringArray(_pL, _Ws.RevertUnchanged(change));
                    return 1;
                });
        }

        // gitgud.p4Submit(change, description, paths?) -> submitted change number
        int LP4Submit(lua_State* _pL)
        {
            const std::string change = luaL_checkstring(_pL, 1);
            const std::string desc = luaL_checkstring(_pL, 2);
            const std::vector<std::string> paths = OptList(_pL, 3);
            return P4Call(_pL, true,
                [&](P4Workspace& _Ws)
                {
                    const std::string submitted = _Ws.SubmitPending(change, desc, paths);
                    lua_pushlstring(_pL, submitted.data(), submitted.size());
                    return 1;
                });
        }

        // gitgud.p4Shelve(change, paths?, revert?) -> change
        int LP4Shelve(lua_State* _pL)
        {
            const std::string change = luaL_checkstring(_pL, 1);
            const std::vector<std::string> paths = OptList(_pL, 2);
            const bool brevert = lua_toboolean(_pL, 3) != 0;
            return P4Call(_pL, true,
                [&](P4Workspace& _Ws)
                {
                    const std::string held = _Ws.ShelveChange(change, paths, brevert);
                    lua_pushlstring(_pL, held.data(), held.size());
                    return 1;
                });
        }

        // gitgud.p4Unshelve(fromChange, toChange?, paths?) -> {applied, conflicted}
        int LP4Unshelve(lua_State* _pL)
        {
            const std::string from = luaL_checkstring(_pL, 1);
            const std::string to = OptString(_pL, 2, "default");
            const std::vector<std::string> paths = OptList(_pL, 3);
            return P4Call(_pL, true,
                [&](P4Workspace& _Ws)
                {
                    const gitgud::git::UnshelveResult r = _Ws.UnshelveChange(from, to, paths);
                    lua_createtable(_pL, 0, 2);
                    PushStringArray(_pL, r.m_Applied);
                    lua_setfield(_pL, -2, "applied");
                    PushStringArray(_pL, r.m_Conflicted);
                    lua_setfield(_pL, -2, "conflicted");
                    return 1;
                });
        }

        // gitgud.p4DeleteShelf(change, paths?)
        int LP4DeleteShelf(lua_State* _pL)
        {
            const std::string change = luaL_checkstring(_pL, 1);
            const std::vector<std::string> paths = OptList(_pL, 2);
            return P4Call(_pL, true,
                [&](P4Workspace& _Ws)
                {
                    _Ws.DeleteShelf(change, paths);
                    lua_pushboolean(_pL, 1);
                    return 1;
                });
        }

        // gitgud.p4Shelves(allUsers?) -> {{change, description, user ("name@client"), time}}
        int LP4Shelves(lua_State* _pL)
        {
            const bool ball = lua_toboolean(_pL, 1) != 0;
            return P4Call(_pL, false,
                [&](P4Workspace& _Ws)
                {
                    const auto shelves = _Ws.ListShelves(ball);
                    lua_createtable(_pL, static_cast<int>(shelves.size()), 0);
                    int i = 1;
                    for (const auto& s : shelves)
                    {
                        lua_createtable(_pL, 0, 4);
                        SetField(_pL, "change", s.m_Change);
                        SetField(_pL, "description", s.m_Description);
                        SetField(_pL, "user", s.m_User);
                        SetField(_pL, "time", static_cast<lua_Integer>(s.m_TimeUtc));
                        lua_rawseti(_pL, -2, i++);
                    }
                    return 1;
                });
        }

        // gitgud.p4ShelvedFiles(change) -> {{path, depotFile, action}}
        int LP4ShelvedFiles(lua_State* _pL)
        {
            const std::string change = luaL_checkstring(_pL, 1);
            return P4Call(_pL, false,
                [&](P4Workspace& _Ws)
                {
                    const auto files = _Ws.ShelvedFiles(change);
                    lua_createtable(_pL, static_cast<int>(files.size()), 0);
                    int i = 1;
                    for (const auto& f : files)
                    {
                        lua_createtable(_pL, 0, 3);
                        SetField(_pL, "path", f.m_Path);
                        SetField(_pL, "depotFile", f.m_DepotFile);
                        SetField(_pL, "action", f.m_Action);
                        lua_rawseti(_pL, -2, i++);
                    }
                    return 1;
                });
        }

        // gitgud.p4Reconcile(paths?) -> opens offline edits, adds, and deletes
        // in the default changelist ("Reconcile Offline Work")
        int LP4Reconcile(lua_State* _pL)
        {
            const std::vector<std::string> paths = OptList(_pL, 1);
            return P4Call(_pL, true,
                [&](P4Workspace& _Ws)
                {
                    if (paths.empty())
                    {
                        std::vector<gitgud::git::StatusEntry> status = _Ws.Status();
                        std::vector<std::string> all;
                        for (const auto& e : status)
                        {
                            if (!e.m_bStaged && e.m_cCode != 'U')
                            {
                                all.push_back(e.m_Path);
                            }
                        }
                        _Ws.Stage(all);
                    }
                    else
                    {
                        _Ws.Stage(paths);
                    }
                    lua_pushboolean(_pL, 1);
                    return 1;
                });
        }

        // gitgud.p4Lock(paths, lock)
        int LP4Lock(lua_State* _pL)
        {
            const std::vector<std::string> paths = StringList(_pL, 1);
            const bool block = lua_isnoneornil(_pL, 2) || lua_toboolean(_pL, 2) != 0;
            return P4Call(_pL, true,
                [&](P4Workspace& _Ws)
                {
                    _Ws.Lock(paths, block);
                    lua_pushboolean(_pL, 1);
                    return 1;
                });
        }

        // gitgud.p4FileStates(dir, recursive?) -> {{path, depotFile, haveRev,
        //   headRev, headAction, headType, openAction, openChange, otherOpen, otherLock}}
        int LP4FileStates(lua_State* _pL)
        {
            const std::string dir = OptString(_pL, 1, "");
            const bool brecursive = lua_toboolean(_pL, 2) != 0;
            return P4Call(_pL, false,
                [&](P4Workspace& _Ws)
                {
                    const auto states = _Ws.FileStates(dir, brecursive);
                    lua_createtable(_pL, static_cast<int>(states.size()), 0);
                    int i = 1;
                    for (const auto& s : states)
                    {
                        lua_createtable(_pL, 0, 10);
                        SetField(_pL, "path", s.m_Path);
                        SetField(_pL, "depotFile", s.m_DepotFile);
                        SetField(_pL, "haveRev", static_cast<lua_Integer>(s.m_iHaveRev));
                        SetField(_pL, "headRev", static_cast<lua_Integer>(s.m_iHeadRev));
                        SetField(_pL, "headAction", s.m_HeadAction);
                        SetField(_pL, "headType", s.m_HeadType);
                        SetField(_pL, "openAction", s.m_OpenAction);
                        SetField(_pL, "openChange", s.m_OpenChange);
                        PushStringArray(_pL, s.m_OtherOpen);
                        lua_setfield(_pL, -2, "otherOpen");
                        SetField(_pL, "otherLock", s.m_bOtherLock);
                        lua_rawseti(_pL, -2, i++);
                    }
                    return 1;
                });
        }

        // ---- worker jobs -------------------------------------------------------------

        // Run `_Job` on a worker; it answers "<_Op>.done" with its string, or
        // "<_Op>.error".
        int RunJob(lua_State* _pL, const std::string& _Op, std::function<std::string()> _Job)
        {
            auto* ptasks = Self(_pL)->TaskRunner();
            if (!ptasks)
            {
                lua_pushboolean(_pL, 0);
                return 1;
            }
            ptasks->Run(_Op, std::move(_Job));
            lua_pushboolean(_pL, 1);
            return 1;
        }

        gitgud::p4::PasswordProvider Passwords(lua_State* _pL)
        {
            LuaEngine* pengine = Self(_pL);
            return P4Workspace::FromCredentialProvider(
                MakeCredentialProvider(pengine->CredentialStore(), pengine->EventBus()));
        }

        // gitgud.p4Sync(paths?, revision?) -> async "p4Sync.done" (detail: files
        // left alone because you changed them, one per line) / "p4Sync.error"
        int LP4Sync(lua_State* _pL)
        {
            auto* prepo = Self(_pL)->Repository();
            if (!prepo || !prepo->P4())
            {
                return FailWith(_pL, "This repository is not a Perforce workspace");
            }
            const std::vector<std::string> paths = OptList(_pL, 1);
            const std::string revision = OptString(_pL, 2, "");
            const std::string root = prepo->Path();
            auto passwords = Passwords(_pL);
            return RunJob(_pL, "p4Sync",
                [root, paths, revision, passwords]()
                {
                    auto ws = P4Workspace::Open(root);
                    ws->SetPasswordProvider(passwords);
                    std::string out;
                    for (const std::string& line : ws->SyncPaths(paths, revision))
                    {
                        out += line + "\n";
                    }
                    return out;
                });
        }

        // gitgud.p4ListStreams({port, user, charset}) -> async "p4Streams.done":
        // one "stream\tname\tparent\ttype" line per stream
        int LP4ListStreams(lua_State* _pL)
        {
            const gitgud::p4::Connection conn = ConnectionArg(_pL, 1);
            auto passwords = Passwords(_pL);
            return RunJob(_pL, "p4Streams",
                [conn, passwords]()
                {
                    std::string out;
                    for (const auto& s : P4Workspace::ListStreams(conn, passwords))
                    {
                        out += s.m_Stream + "\t" + s.m_Name + "\t" + s.m_Parent + "\t" + s.m_Type +
                               "\n";
                    }
                    return out;
                });
        }

        // gitgud.p4ListDepots({port, user, charset}) -> async "p4Depots.done":
        // one "name\ttype" line per depot
        int LP4ListDepots(lua_State* _pL)
        {
            const gitgud::p4::Connection conn = ConnectionArg(_pL, 1);
            auto passwords = Passwords(_pL);
            return RunJob(_pL, "p4Depots",
                [conn, passwords]()
                {
                    std::string out;
                    for (const auto& d : P4Workspace::ListDepots(conn, passwords))
                    {
                        out += d.m_Name + "\t" + d.m_Type + "\n";
                    }
                    return out;
                });
        }

        // gitgud.p4ListWorkspaces({port, user, charset}) -> async
        // "p4Workspaces.done": one "name\troot\tstream\thost" line per workspace
        int LP4ListWorkspaces(lua_State* _pL)
        {
            const gitgud::p4::Connection conn = ConnectionArg(_pL, 1);
            auto passwords = Passwords(_pL);
            return RunJob(_pL, "p4Workspaces",
                [conn, passwords]()
                {
                    std::string out;
                    for (const auto& w : P4Workspace::ListWorkspaces(conn, passwords))
                    {
                        out +=
                            w.m_Name + "\t" + w.m_Root + "\t" + w.m_Stream + "\t" + w.m_Host + "\n";
                    }
                    return out;
                });
        }

        // gitgud.p4CreateWorkspace({port, user, password?, charset?, client?, root,
        //   stream? | depotPath + branchRoot?, create?, sync?}) -> async
        //   "p4CreateWorkspace.done" (detail: the root, ready for gitgud.openRepo)
        int LP4CreateWorkspace(lua_State* _pL)
        {
            luaL_checktype(_pL, 1, LUA_TTABLE);
            const auto field = [&](const char* _szKey)
            {
                lua_getfield(_pL, 1, _szKey);
                std::string v = lua_type(_pL, -1) == LUA_TSTRING ? lua_tostring(_pL, -1) : "";
                lua_pop(_pL, 1);
                return v;
            };
            gitgud::p4::WorkspaceSetup setup;
            setup.m_Port = field("port");
            setup.m_User = field("user");
            setup.m_Password = field("password");
            setup.m_Charset = field("charset");
            setup.m_Client = field("client");
            setup.m_Root = field("root");
            setup.m_Stream = field("stream");
            setup.m_DepotPath = field("depotPath");
            setup.m_BranchRoot = field("branchRoot");
            lua_getfield(_pL, 1, "create");
            setup.m_bCreate = lua_toboolean(_pL, -1) != 0;
            lua_pop(_pL, 1);
            lua_getfield(_pL, 1, "sync");
            setup.m_bSync = lua_isnil(_pL, -1) || lua_toboolean(_pL, -1) != 0;
            lua_pop(_pL, 1);
            auto passwords = Passwords(_pL);
            return RunJob(_pL, "p4CreateWorkspace",
                [setup, passwords]()
                {
                    auto ws = P4Workspace::Create(setup, passwords);
                    return ws->WorkDir();
                });
        }

        // gitgud.p4Login(port, user, password) -> true | (nil, message). The
        // ticket stays in memory; save the password with
        // gitgud.setCredential("p4:" .. port, user, password) to log in again later.
        int LP4Login(lua_State* _pL)
        {
            gitgud::p4::Connection conn;
            conn.m_Port = luaL_checkstring(_pL, 1);
            conn.m_User = luaL_checkstring(_pL, 2);
            const std::string password = luaL_checkstring(_pL, 3);
            std::string error;
            if (!gitgud::p4::P4Command::Login(conn, password, error))
            {
                return FailWith(_pL, error);
            }
            lua_pushboolean(_pL, 1);
            return 1;
        }

        // gitgud.p4Trust(port, fingerprint?) -> true | (nil, message). Trusts an
        // ssl: server's certificate (p4 trust -y), or checks it against
        // `fingerprint` first when one is given.
        int LP4Trust(lua_State* _pL)
        {
            gitgud::p4::Connection conn;
            conn.m_Port = luaL_checkstring(_pL, 1);
            std::vector<std::string> args = {"trust", "-y"};
            if (lua_type(_pL, 2) == LUA_TSTRING)
            {
                args = {"trust", "-i", lua_tostring(_pL, 2)};
            }
            const auto r = gitgud::p4::P4Command::RunText(conn, args, "");
            if (!r.Ok())
            {
                return FailWith(_pL, r.Message());
            }
            lua_pushboolean(_pL, 1);
            return 1;
        }

    } // namespace

    void AddP4Bindings(std::vector<luaL_Reg>& _Out)
    {
        const luaL_Reg kFunctions[] = {
            {"backend", LBackend},
            {"supports", LSupports},
            {"p4Available", LP4Available},
            {"p4Info", LP4Info},
            {"p4Changes", LP4Changes},
            {"p4NewChange", LP4NewChange},
            {"p4SetDescription", LP4SetDescription},
            {"p4DeleteChange", LP4DeleteChange},
            {"p4Reopen", LP4Reopen},
            {"p4Edit", LP4Edit},
            {"p4Add", LP4Add},
            {"p4Delete", LP4Delete},
            {"p4Move", LP4Move},
            {"p4Revert", LP4Revert},
            {"p4RevertUnchanged", LP4RevertUnchanged},
            {"p4Submit", LP4Submit},
            {"p4Shelve", LP4Shelve},
            {"p4Unshelve", LP4Unshelve},
            {"p4DeleteShelf", LP4DeleteShelf},
            {"p4Shelves", LP4Shelves},
            {"p4ShelvedFiles", LP4ShelvedFiles},
            {"p4Reconcile", LP4Reconcile},
            {"p4Lock", LP4Lock},
            {"p4FileStates", LP4FileStates},
            {"p4Sync", LP4Sync},
            {"p4ListStreams", LP4ListStreams},
            {"p4ListDepots", LP4ListDepots},
            {"p4ListWorkspaces", LP4ListWorkspaces},
            {"p4CreateWorkspace", LP4CreateWorkspace},
            {"p4Login", LP4Login},
            {"p4Trust", LP4Trust},
        };
        _Out.insert(_Out.end(), std::begin(kFunctions), std::end(kFunctions));
    }

} // namespace gitgud::lua::bindings
