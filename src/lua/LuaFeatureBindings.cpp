// -----------------------------------------------------------------------------
// LuaFeatureBindings — the `gitgud` functions behind the GitKraken-style
// features: the commit graph (with its row pictures), reflog and branch moves
// for Undo/Redo, the 3-pane conflict tool, interactive rebase, file history
// and blame, submodules, worktrees, Git LFS, SSH keys and host trust, and the
// console (running commands with streamed output).
//
// Same conventions as the rest of the table (docs/LUA_API.md): sync calls
// return a value or (nil, "message"); mutations publish "status.changed";
// async work reports "<op>.done" / "<op>.error".
// -----------------------------------------------------------------------------

#include "lua/LuaBindings.h"

#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <memory>
#include <sstream>

#include "app/EventBus.h"
#include "app/TaskRunner.h"
#include "git/CommitGraph.h"
#include "git/Repository.h"
#include "imaging/GraphRenderer.h"
#include "platform/Process.h"
#include "ui/IUiBackend.h"

namespace gitgud::lua::bindings
{

    namespace
    {

        namespace fs = std::filesystem;
        using gitgud::git::GitError;
        using gitgud::git::Repository;

        void PublishStatusChanged(LuaEngine* _pEngine)
        {
            if (auto* pbus = _pEngine->EventBus())
            {
                pbus->Publish({"status.changed", ""});
            }
        }

        // A read-only query: no repository -> empty table; errors -> (nil, msg).
        template <typename Fn> int Query(lua_State* _pL, Fn&& _Fn)
        {
            auto* prepo = Self(_pL)->Repository();
            if (!prepo)
            {
                return NoRepo(_pL);
            }
            try
            {
                return _Fn(*prepo);
            }
            catch (const GitError& e)
            {
                return FailWith(_pL, e.what());
            }
        }

        // A mutation: true | (nil, msg), publishing status.changed on success.
        template <typename Fn> int Action(lua_State* _pL, Fn&& _Fn)
        {
            LuaEngine* pengine = Self(_pL);
            auto* prepo = pengine->Repository();
            if (!prepo)
            {
                return NoRepo(_pL);
            }
            try
            {
                _Fn(*prepo);
                PublishStatusChanged(pengine);
                lua_pushboolean(_pL, 1);
                return 1;
            }
            catch (const GitError& e)
            {
                return FailWith(_pL, e.what());
            }
        }

        void PushCommit(lua_State* _pL, const gitgud::git::CommitInfo& _C)
        {
            lua_createtable(_pL, 0, 9);
            SetField(_pL, "oid", _C.m_Oid);
            SetField(_pL, "shortOid", _C.m_ShortOid);
            SetField(_pL, "summary", _C.m_Summary);
            SetField(_pL, "message", _C.m_Message);
            SetField(_pL, "author", _C.m_AuthorName);
            SetField(_pL, "email", _C.m_AuthorEmail);
            SetField(_pL, "time", static_cast<lua_Integer>(_C.m_TimeUtc));
            PushStringArray(_pL, _C.m_Parents);
            lua_setfield(_pL, -2, "parents");
        }

        void PushCommits(lua_State* _pL, const std::vector<gitgud::git::CommitInfo>& _Commits)
        {
            lua_createtable(_pL, static_cast<int>(_Commits.size()), 0);
            int idx = 1;
            for (const auto& c : _Commits)
            {
                PushCommit(_pL, c);
                lua_rawseti(_pL, -2, idx++);
            }
        }

        // Optional table field helpers.
        lua_Integer IntField(lua_State* _pL, int _iTable, const char* _szKey, lua_Integer _Default)
        {
            if (!lua_istable(_pL, _iTable))
            {
                return _Default;
            }
            lua_getfield(_pL, _iTable, _szKey);
            const lua_Integer v = lua_isinteger(_pL, -1) ? lua_tointeger(_pL, -1) : _Default;
            lua_pop(_pL, 1);
            return v;
        }

        bool BoolField(lua_State* _pL, int _iTable, const char* _szKey, bool _bDefault)
        {
            if (!lua_istable(_pL, _iTable))
            {
                return _bDefault;
            }
            lua_getfield(_pL, _iTable, _szKey);
            const bool b = lua_isnil(_pL, -1) ? _bDefault : lua_toboolean(_pL, -1) != 0;
            lua_pop(_pL, 1);
            return b;
        }

        std::string StringField(
            lua_State* _pL, int _iTable, const char* _szKey, const std::string& _Default)
        {
            if (!lua_istable(_pL, _iTable))
            {
                return _Default;
            }
            lua_getfield(_pL, _iTable, _szKey);
            std::string v = _Default;
            if (lua_type(_pL, -1) == LUA_TSTRING)
            {
                v = lua_tostring(_pL, -1);
            }
            lua_pop(_pL, 1);
            return v;
        }

        // "FF7EF2D6" / "7EF2D6" -> 0xRRGGBB
        std::uint32_t ParseColour(const std::string& _Hex, std::uint32_t _uiDefault)
        {
            std::string hex = _Hex;
            if (hex.size() == 8)
            {
                hex = hex.substr(2);
            }
            if (hex.size() != 6)
            {
                return _uiDefault;
            }
            try
            {
                return static_cast<std::uint32_t>(std::stoul(hex, nullptr, 16));
            }
            catch (...)
            {
                return _uiDefault;
            }
        }

        std::string HomeDir()
        {
            const char* szhome = std::getenv("USERPROFILE");
            if (!szhome)
            {
                szhome = std::getenv("HOME");
            }
            return szhome ? szhome : "";
        }

        // ---- commit graph ---------------------------------------------------------

        // gitgud.graph({max, remotes, tags, wip, laneWidth, rowHeight, maxLanes,
        //   colours = {"AARRGGBB", ...}, background, headRing, prefix})
        //   -> {rows = {commit + lane, colour, image, merge, head, wip}, width, lanes}
        // Each row's picture is published as image "<prefix>/<row>" (the rows
        // share a few atlas textures).
        int LGraph(lua_State* _pL)
        {
            LuaEngine* pengine = Self(_pL);
            auto* prepo = pengine->Repository();
            if (!prepo)
            {
                return NoRepo(_pL);
            }

            gitgud::git::GraphQuery query;
            query.m_MaxCount = static_cast<std::size_t>(IntField(_pL, 1, "max", 400));
            query.m_bRemotes = BoolField(_pL, 1, "remotes", true);
            query.m_bTags = BoolField(_pL, 1, "tags", true);
            const bool bwip = BoolField(_pL, 1, "wip", false);
            const std::string prefix = StringField(_pL, 1, "prefix", "GitgudGraph");

            gitgud::imaging::GraphStyle style;
            style.m_iLaneWidth = static_cast<int>(IntField(_pL, 1, "laneWidth", 16));
            style.m_iRowHeight = static_cast<int>(IntField(_pL, 1, "rowHeight", 28));
            const int imaxLanes = static_cast<int>(IntField(_pL, 1, "maxLanes", 12));
            style.m_uiBackground = ParseColour(StringField(_pL, 1, "background", ""), 0x1F1738);
            style.m_uiHeadRing = ParseColour(StringField(_pL, 1, "headRing", ""), 0xF3EEFC);
            if (lua_istable(_pL, 1))
            {
                lua_getfield(_pL, 1, "colours");
                if (lua_istable(_pL, -1))
                {
                    std::vector<std::uint32_t> colours;
                    const lua_Integer n = luaL_len(_pL, -1);
                    for (lua_Integer i = 1; i <= n; ++i)
                    {
                        lua_rawgeti(_pL, -1, i);
                        if (const char* sz = lua_tostring(_pL, -1))
                        {
                            colours.push_back(ParseColour(sz, 0x7EF2D6));
                        }
                        lua_pop(_pL, 1);
                    }
                    if (!colours.empty())
                    {
                        style.m_Colours = colours;
                    }
                }
                lua_pop(_pL, 1);
            }

            std::vector<gitgud::git::CommitInfo> commits;
            std::string headOid;
            try
            {
                commits = prepo->GraphLog(query);
                headOid = prepo->HeadOid();
            }
            catch (const GitError& e)
            {
                return FailWith(_pL, e.what());
            }

            // The optional "uncommitted changes" row sits above HEAD.
            const bool bwipRow = bwip && !headOid.empty();
            std::vector<gitgud::git::GraphNode> nodes;
            std::vector<std::uint8_t> flags;
            if (bwipRow)
            {
                nodes.push_back({"WIP", {headOid}});
                flags.push_back(gitgud::imaging::kGraphWip);
            }
            for (const auto& c : commits)
            {
                nodes.push_back({c.m_Oid, c.m_Parents});
                std::uint8_t uflags = 0;
                if (c.m_Parents.size() > 1)
                {
                    uflags |= gitgud::imaging::kGraphMerge;
                }
                if (c.m_Oid == headOid)
                {
                    uflags |= gitgud::imaging::kGraphHead;
                }
                flags.push_back(uflags);
            }

            const std::vector<gitgud::git::GraphRow> rows = gitgud::git::LayoutGraph(nodes);
            int ilanes = 1;
            for (const auto& row : rows)
            {
                ilanes = std::max(ilanes, row.m_iLaneCount);
            }
            style.m_iLanes = std::min(ilanes, std::max(1, imaxLanes));

            // Render into atlas textures of at most ~8K pixels high.
            auto* pui = pengine->UiBackend();
            const std::size_t nperTexture =
                std::max<std::size_t>(1, static_cast<std::size_t>(8192 / style.m_iRowHeight));
            if (pui)
            {
                for (std::size_t nfirst = 0; nfirst < rows.size(); nfirst += nperTexture)
                {
                    const std::size_t ncount = std::min(nperTexture, rows.size() - nfirst);
                    const gitgud::imaging::Image img =
                        gitgud::imaging::RenderGraphRows(rows, flags, nfirst, ncount, style);
                    std::vector<gitgud::ui::ImageRegion> regions;
                    for (std::size_t i = 0; i < ncount; ++i)
                    {
                        gitgud::ui::ImageRegion region;
                        region.m_Name = prefix + "/" + std::to_string(nfirst + i + 1);
                        region.m_iX = 0;
                        region.m_iY = static_cast<int>(i) * style.m_iRowHeight;
                        region.m_iWidth = img.m_iWidth;
                        region.m_iHeight = style.m_iRowHeight;
                        regions.push_back(std::move(region));
                    }
                    pui->DefineImageAtlas(prefix + "#" + std::to_string(nfirst / nperTexture),
                        img.m_iWidth, img.m_iHeight, img.m_Rgba, regions);
                }
            }

            lua_createtable(_pL, 0, 3);
            SetField(_pL, "width", static_cast<lua_Integer>(gitgud::imaging::GraphWidth(style)));
            SetField(_pL, "lanes", static_cast<lua_Integer>(style.m_iLanes));
            lua_createtable(_pL, static_cast<int>(rows.size()), 0);
            const std::size_t noffset = bwipRow ? 1 : 0;
            for (std::size_t i = 0; i < rows.size(); ++i)
            {
                if (i < noffset)
                {
                    lua_createtable(_pL, 0, 5);
                    SetField(_pL, "wip", true);
                    SetField(_pL, "oid", "");
                }
                else
                {
                    PushCommit(_pL, commits[i - noffset]);
                    SetField(_pL, "merge", (flags[i] & gitgud::imaging::kGraphMerge) != 0);
                    SetField(_pL, "head", (flags[i] & gitgud::imaging::kGraphHead) != 0);
                }
                SetField(_pL, "lane", static_cast<lua_Integer>(rows[i].m_iLane + 1));
                SetField(_pL, "colour", static_cast<lua_Integer>(rows[i].m_iColour + 1));
                SetField(_pL, "image", prefix + "/" + std::to_string(i + 1));
                lua_rawseti(_pL, -2, static_cast<lua_Integer>(i + 1));
            }
            lua_setfield(_pL, -2, "rows");
            return 1;
        }

        // ---- undo support -----------------------------------------------------------

        int LHeadOid(lua_State* _pL)
        {
            auto* prepo = Self(_pL)->Repository();
            std::string oid;
            if (prepo)
            {
                try
                {
                    oid = prepo->HeadOid();
                }
                catch (const GitError&)
                {
                }
            }
            lua_pushlstring(_pL, oid.data(), oid.size());
            return 1;
        }

        // gitgud.reflog(ref = "HEAD", max = 50) -> {{old, new, message, committer, time}}
        int LReflog(lua_State* _pL)
        {
            const std::string ref = luaL_optstring(_pL, 1, "HEAD");
            const auto nmax = static_cast<std::size_t>(luaL_optinteger(_pL, 2, 50));
            return Query(_pL,
                [&](Repository& _R)
                {
                    const auto entries = _R.Reflog(ref, nmax);
                    lua_createtable(_pL, static_cast<int>(entries.size()), 0);
                    int idx = 1;
                    for (const auto& e : entries)
                    {
                        lua_createtable(_pL, 0, 5);
                        SetField(_pL, "old", e.m_OldOid);
                        SetField(_pL, "new", e.m_NewOid);
                        SetField(_pL, "message", e.m_Message);
                        SetField(_pL, "committer", e.m_Committer);
                        SetField(_pL, "time", static_cast<lua_Integer>(e.m_TimeUtc));
                        lua_rawseti(_pL, -2, idx++);
                    }
                    return 1;
                });
        }

        // gitgud.setBranchTarget(branch, oid)
        int LSetBranchTarget(lua_State* _pL)
        {
            const std::string name = luaL_checkstring(_pL, 1);
            const std::string oid = luaL_checkstring(_pL, 2);
            return Action(_pL, [&](Repository& _R) { _R.SetBranchTarget(name, oid); });
        }

        // ---- conflicts -------------------------------------------------------------------

        // gitgud.readConflict(path) -> {binary, oursDeleted, theirsDeleted,
        //   trailingNewline, chunks = {{conflict, lines, ours, theirs, base}}}
        int LReadConflict(lua_State* _pL)
        {
            const std::string path = luaL_checkstring(_pL, 1);
            return Query(_pL,
                [&](Repository& _R)
                {
                    const auto file = _R.ReadConflict(path);
                    lua_createtable(_pL, 0, 6);
                    SetField(_pL, "path", file.m_Path);
                    SetField(_pL, "binary", file.m_bBinary);
                    SetField(_pL, "oursDeleted", file.m_bOursDeleted);
                    SetField(_pL, "theirsDeleted", file.m_bTheirsDeleted);
                    SetField(_pL, "trailingNewline", file.m_bTrailingNewline);
                    lua_createtable(_pL, static_cast<int>(file.m_Chunks.size()), 0);
                    int idx = 1;
                    for (const auto& chunk : file.m_Chunks)
                    {
                        lua_createtable(_pL, 0, 5);
                        SetField(_pL, "conflict", chunk.m_bConflict);
                        PushStringArray(_pL, chunk.m_Lines);
                        lua_setfield(_pL, -2, "lines");
                        PushStringArray(_pL, chunk.m_Ours);
                        lua_setfield(_pL, -2, "ours");
                        PushStringArray(_pL, chunk.m_Theirs);
                        lua_setfield(_pL, -2, "theirs");
                        PushStringArray(_pL, chunk.m_Base);
                        lua_setfield(_pL, -2, "base");
                        lua_rawseti(_pL, -2, idx++);
                    }
                    lua_setfield(_pL, -2, "chunks");
                    return 1;
                });
        }

        // ---- interactive rebase --------------------------------------------------------

        int LRebaseTodo(lua_State* _pL)
        {
            const std::string base = luaL_checkstring(_pL, 1);
            return Query(_pL,
                [&](Repository& _R)
                {
                    PushCommits(_pL, _R.RebaseTodo(base));
                    return 1;
                });
        }

        // gitgud.interactiveRebase(base, {{action = "pick"|"reword"|"squash"|
        //   "fixup"|"drop", oid, message}, ...}) -> {kind, message, conflicts}
        int LInteractiveRebase(lua_State* _pL)
        {
            using Action = gitgud::git::RebaseStep::Action;
            const std::string base = luaL_checkstring(_pL, 1);
            luaL_checktype(_pL, 2, LUA_TTABLE);

            std::vector<gitgud::git::RebaseStep> steps;
            const lua_Integer n = luaL_len(_pL, 2);
            for (lua_Integer i = 1; i <= n; ++i)
            {
                lua_rawgeti(_pL, 2, i);
                const int itop = lua_gettop(_pL);
                gitgud::git::RebaseStep step;
                const std::string action = StringField(_pL, itop, "action", "pick");
                step.m_Oid = StringField(_pL, itop, "oid", "");
                step.m_Message = StringField(_pL, itop, "message", "");
                if (action == "reword")
                {
                    step.m_Action = Action::Reword;
                }
                else if (action == "squash")
                {
                    step.m_Action = Action::Squash;
                }
                else if (action == "fixup")
                {
                    step.m_Action = Action::Fixup;
                }
                else if (action == "drop")
                {
                    step.m_Action = Action::Drop;
                }
                steps.push_back(std::move(step));
                lua_pop(_pL, 1);
            }

            LuaEngine* pengine = Self(_pL);
            auto* prepo = pengine->Repository();
            if (!prepo)
            {
                return NoRepo(_pL);
            }
            try
            {
                const auto result = prepo->InteractiveRebase(base, steps);
                PublishStatusChanged(pengine);
                using Kind = gitgud::git::RebaseResult::Kind;
                lua_createtable(_pL, 0, 3);
                SetField(_pL, "kind",
                    result.m_Kind == Kind::Done
                        ? "done"
                        : (result.m_Kind == Kind::Conflicts ? "conflicts" : "uptodate"));
                SetField(_pL, "message", result.m_Message);
                PushStringArray(_pL, result.m_ConflictedPaths);
                lua_setfield(_pL, -2, "conflicts");
                return 1;
            }
            catch (const GitError& e)
            {
                return FailWith(_pL, e.what());
            }
        }

        // ---- file history / blame ---------------------------------------------------------

        int LFileLog(lua_State* _pL)
        {
            const std::string path = luaL_checkstring(_pL, 1);
            const auto nmax = static_cast<std::size_t>(luaL_optinteger(_pL, 2, 300));
            return Query(_pL,
                [&](Repository& _R)
                {
                    PushCommits(_pL, _R.FileLog(path, nmax));
                    return 1;
                });
        }

        // gitgud.blame(path, revision = "workdir") -> {lines, hunks = {{oid,
        //   shortOid, summary, author, time, start, count, uncommitted}}}
        int LBlame(lua_State* _pL)
        {
            const std::string path = luaL_checkstring(_pL, 1);
            const std::string revision = luaL_optstring(_pL, 2, "workdir");
            return Query(_pL,
                [&](Repository& _R)
                {
                    const auto blame = _R.Blame(path, revision);
                    lua_createtable(_pL, 0, 2);
                    PushStringArray(_pL, blame.m_Lines);
                    lua_setfield(_pL, -2, "lines");
                    lua_createtable(_pL, static_cast<int>(blame.m_Hunks.size()), 0);
                    int idx = 1;
                    for (const auto& h : blame.m_Hunks)
                    {
                        lua_createtable(_pL, 0, 8);
                        SetField(_pL, "oid", h.m_Oid);
                        SetField(_pL, "shortOid", h.m_Oid.substr(0, 7));
                        SetField(_pL, "summary", h.m_Summary);
                        SetField(_pL, "author", h.m_Author);
                        SetField(_pL, "time", static_cast<lua_Integer>(h.m_TimeUtc));
                        SetField(_pL, "start", static_cast<lua_Integer>(h.m_StartLine));
                        SetField(_pL, "count", static_cast<lua_Integer>(h.m_LineCount));
                        SetField(_pL, "uncommitted", h.m_bUncommitted);
                        lua_rawseti(_pL, -2, idx++);
                    }
                    lua_setfield(_pL, -2, "hunks");
                    return 1;
                });
        }

        // ---- submodules / worktrees / LFS ---------------------------------------------

        int LSubmodules(lua_State* _pL)
        {
            return Query(_pL,
                [&](Repository& _R)
                {
                    const auto subs = _R.Submodules();
                    lua_createtable(_pL, static_cast<int>(subs.size()), 0);
                    int idx = 1;
                    for (const auto& s : subs)
                    {
                        lua_createtable(_pL, 0, 8);
                        SetField(_pL, "name", s.m_Name);
                        SetField(_pL, "path", s.m_Path);
                        SetField(_pL, "url", s.m_Url);
                        SetField(_pL, "headOid", s.m_HeadOid);
                        SetField(_pL, "workdirOid", s.m_WorkdirOid);
                        SetField(_pL, "initialized", s.m_bInitialized);
                        SetField(_pL, "modified", s.m_bModified);
                        SetField(_pL, "dirty", s.m_bDirty);
                        lua_rawseti(_pL, -2, idx++);
                    }
                    return 1;
                });
        }

        int LWorktrees(lua_State* _pL)
        {
            return Query(_pL,
                [&](Repository& _R)
                {
                    const auto trees = _R.Worktrees();
                    lua_createtable(_pL, static_cast<int>(trees.size()), 0);
                    int idx = 1;
                    for (const auto& w : trees)
                    {
                        lua_createtable(_pL, 0, 6);
                        SetField(_pL, "name", w.m_Name);
                        SetField(_pL, "path", w.m_Path);
                        SetField(_pL, "branch", w.m_Branch);
                        SetField(_pL, "locked", w.m_bLocked);
                        SetField(_pL, "valid", w.m_bValid);
                        SetField(_pL, "main", w.m_bMain);
                        lua_rawseti(_pL, -2, idx++);
                    }
                    return 1;
                });
        }

        // gitgud.addWorktree(name, path, branch?)
        int LAddWorktree(lua_State* _pL)
        {
            const std::string name = luaL_checkstring(_pL, 1);
            const std::string path = luaL_checkstring(_pL, 2);
            const std::string branch = luaL_optstring(_pL, 3, "");
            return Action(_pL, [&](Repository& _R) { _R.AddWorktree(name, path, branch); });
        }

        int LRemoveWorktree(lua_State* _pL)
        {
            const std::string name = luaL_checkstring(_pL, 1);
            return Action(_pL, [&](Repository& _R) { _R.RemoveWorktree(name); });
        }

        int LLfsAvailable(lua_State* _pL)
        {
            lua_pushboolean(_pL, Repository::LfsAvailable());
            return 1;
        }

        // ---- programs, SSH -------------------------------------------------------------------

        // gitgud.findProgram(name) -> full path or nil
        int LFindProgram(lua_State* _pL)
        {
            const std::string path = gitgud::platform::FindProgram(luaL_checkstring(_pL, 1));
            if (path.empty())
            {
                lua_pushnil(_pL);
            }
            else
            {
                lua_pushlstring(_pL, path.data(), path.size());
            }
            return 1;
        }

        // gitgud.runProgram({program, args...}, cwd?, stdin?) -> {code, output, error}
        // or (nil, message). BLOCKS: only for quick tools (ssh-keygen, git lfs version).
        int LRunProgram(lua_State* _pL)
        {
            const std::vector<std::string> args = StringList(_pL, 1);
            const std::string cwd = luaL_optstring(_pL, 2, "");
            const std::string input = luaL_optstring(_pL, 3, "");
            const auto result = gitgud::platform::RunProcess(args, cwd, input);
            if (!result.m_bStarted)
            {
                return FailWith(_pL, result.m_StartError);
            }
            lua_createtable(_pL, 0, 3);
            SetField(_pL, "code", static_cast<lua_Integer>(result.m_iExitCode));
            SetField(_pL, "output", result.m_Output);
            SetField(_pL, "error", result.m_Error);
            return 1;
        }

        // The running console command's cancel flag (one command at a time).
        std::shared_ptr<std::atomic<bool>> g_ConsoleCancel;
        std::atomic<bool> g_bConsoleBusy{false};

        // gitgud.runCommand(commandLine, cwd?) -> true | (nil, msg). Output
        // streams as "console.output" events; "console.done" carries the exit
        // code when it ends.
        int LRunCommand(lua_State* _pL)
        {
            LuaEngine* pengine = Self(_pL);
            const std::string command = luaL_checkstring(_pL, 1);
            std::string cwd = luaL_optstring(_pL, 2, "");
            auto* ptasks = pengine->TaskRunner();
            auto* pbus = pengine->EventBus();
            if (!ptasks || !pbus)
            {
                return FailWith(_pL, "no task runner");
            }
            if (g_bConsoleBusy.exchange(true))
            {
                return FailWith(_pL, "A command is already running");
            }
            if (cwd.empty() && pengine->Repository())
            {
                cwd = pengine->Repository()->WorkDir();
            }
            auto cancel = std::make_shared<std::atomic<bool>>(false);
            g_ConsoleCancel = cancel;
            ptasks->Run("console",
                [command, cwd, cancel, pbus]() -> std::string
                {
                    const int icode = gitgud::platform::RunShellStreaming(
                        command, cwd, [pbus](const std::string& _Chunk)
                        { pbus->Publish({"console.output", _Chunk}); }, cancel.get());
                    g_bConsoleBusy = false;
                    return std::to_string(icode);
                });
            lua_pushboolean(_pL, 1);
            return 1;
        }

        int LCancelCommand(lua_State* _pL)
        {
            if (g_ConsoleCancel)
            {
                g_ConsoleCancel->store(true);
            }
            lua_pushboolean(_pL, g_bConsoleBusy.load());
            return 1;
        }

        int LCommandRunning(lua_State* _pL)
        {
            lua_pushboolean(_pL, g_bConsoleBusy.load());
            return 1;
        }

        int LHomeDir(lua_State* _pL)
        {
            const std::string home = HomeDir();
            lua_pushlstring(_pL, home.data(), home.size());
            return 1;
        }

        // gitgud.sshKeys() -> {{name, path, publicKey, comment}} for ~/.ssh/*.pub
        int LSshKeys(lua_State* _pL)
        {
            lua_newtable(_pL);
            const std::string home = HomeDir();
            if (home.empty())
            {
                return 1;
            }
            std::vector<fs::path> files;
            std::error_code ec;
            for (fs::directory_iterator it(fs::u8path(home) / ".ssh", ec), end; !ec && it != end;
                it.increment(ec))
            {
                if (it->path().extension() == ".pub")
                {
                    files.push_back(it->path());
                }
            }
            std::sort(files.begin(), files.end());
            int idx = 1;
            for (const fs::path& pub : files)
            {
                std::ifstream in(pub, std::ios::binary);
                std::string line;
                std::getline(in, line);
                while (!line.empty() && (line.back() == '\r' || line.back() == '\n'))
                {
                    line.pop_back();
                }
                fs::path priv = pub;
                priv.replace_extension();
                lua_createtable(_pL, 0, 4);
                SetField(_pL, "name", priv.filename().u8string());
                SetField(_pL, "path", priv.u8string());
                SetField(_pL, "publicKey", line);
                SetField(_pL, "hasPrivate", fs::exists(priv, ec));
                lua_rawseti(_pL, -2, idx++);
            }
            return 1;
        }

        // gitgud.trustHostKey(knownHostsLine) — append it to ~/.ssh/known_hosts
        int LTrustHostKey(lua_State* _pL)
        {
            const std::string line = luaL_checkstring(_pL, 1);
            if (line.find('\n') != std::string::npos || line.find(' ') == std::string::npos)
            {
                return FailWith(_pL, "not a known_hosts line");
            }
            const std::string home = HomeDir();
            if (home.empty())
            {
                return FailWith(_pL, "no home directory");
            }
            const fs::path dir = fs::u8path(home) / ".ssh";
            std::error_code ec;
            fs::create_directories(dir, ec);
            const fs::path file = dir / "known_hosts";

            // Start on a fresh line even if the file doesn't end with one.
            std::string existing;
            {
                std::ifstream in(file, std::ios::binary);
                std::ostringstream ss;
                ss << in.rdbuf();
                existing = ss.str();
            }
            std::ofstream out(file, std::ios::binary | std::ios::app);
            if (!out)
            {
                return FailWith(_pL, "could not write " + file.u8string());
            }
            if (!existing.empty() && existing.back() != '\n')
            {
                out << "\n";
            }
            out << line << "\n";
            lua_pushboolean(_pL, 1);
            return 1;
        }

    } // namespace

    void AddFeatureBindings(std::vector<luaL_Reg>& _Out)
    {
        const luaL_Reg kFunctions[] = {
            // graph + undo
            {"graph", LGraph},
            {"headOid", LHeadOid},
            {"reflog", LReflog},
            {"setBranchTarget", LSetBranchTarget},
            // conflicts + rewriting
            {"readConflict", LReadConflict},
            {"rebaseTodo", LRebaseTodo},
            {"interactiveRebase", LInteractiveRebase},
            // file history
            {"fileLog", LFileLog},
            {"blame", LBlame},
            // submodules / worktrees / LFS
            {"submodules", LSubmodules},
            {"worktrees", LWorktrees},
            {"addWorktree", LAddWorktree},
            {"removeWorktree", LRemoveWorktree},
            {"lfsAvailable", LLfsAvailable},
            // programs, console, SSH
            {"findProgram", LFindProgram},
            {"runProgram", LRunProgram},
            {"runCommand", LRunCommand},
            {"cancelCommand", LCancelCommand},
            {"commandRunning", LCommandRunning},
            {"homeDir", LHomeDir},
            {"sshKeys", LSshKeys},
            {"trustHostKey", LTrustHostKey},
        };
        _Out.insert(_Out.end(), std::begin(kFunctions), std::end(kFunctions));
    }

} // namespace gitgud::lua::bindings
