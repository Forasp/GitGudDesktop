// -----------------------------------------------------------------------------
// LuaRepoBindings — the git half of the `gitgud` table: repository state,
// staging, commits, branches, history, tags, stash, merge/rebase, network
// operations (on worker threads), and credentials.
//
// Conventions (see docs/LUA_API.md):
//   * sync actions return true/value, or (nil, "message") on failure
//   * async ops return immediately and publish "<op>.started/.done/.error"
//   * every successful mutation publishes "status.changed"
//   * indices are 1-based
// -----------------------------------------------------------------------------

#include "lua/LuaBindings.h"

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>

#include "app/EventBus.h"
#include "app/TaskRunner.h"
#include "git/Repository.h"
#include "platform/ICredentialStore.h"
#include "platform/Shell.h"

namespace gitgud::lua::bindings
{

    namespace
    {

        using gitgud::git::GitError;
        using gitgud::git::Repository;

        void PublishStatusChanged(LuaEngine* _pEngine, const std::string& _Detail = "")
        {
            if (auto* pbus = _pEngine->EventBus())
            {
                pbus->Publish({"status.changed", _Detail});
            }
        }

        // Wrap a void Repository call with the true | (nil, msg) convention and a
        // "status.changed" publish on success.
        template <typename Fn> int RepoAction(lua_State* _pL, Fn&& _Fn)
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

        // Like RepoAction, but the call returns a string handed back to Lua.
        template <typename Fn> int RepoStringAction(lua_State* _pL, Fn&& _Fn)
        {
            LuaEngine* pengine = Self(_pL);
            auto* prepo = pengine->Repository();
            if (!prepo)
            {
                return NoRepo(_pL);
            }
            try
            {
                const std::string result = _Fn(*prepo);
                PublishStatusChanged(pengine);
                lua_pushlstring(_pL, result.data(), result.size());
                return 1;
            }
            catch (const GitError& e)
            {
                return FailWith(_pL, e.what());
            }
        }

        // A read-only query that fills a table; errors are logged and yield
        // whatever was pushed (an empty table by convention).
        template <typename Fn> int RepoQuery(lua_State* _pL, const char* _szName, Fn&& _Fn)
        {
            auto* prepo = Self(_pL)->Repository();
            if (!prepo)
            {
                lua_newtable(_pL);
                return 1;
            }
            const int itop = lua_gettop(_pL);
            try
            {
                return _Fn(*prepo);
            }
            catch (const GitError& e)
            {
                std::fprintf(stderr, "[lua] gitgud.%s() failed: %s\n", _szName, e.what());
                lua_settop(_pL, itop);
                lua_newtable(_pL);
                return 1;
            }
        }

        gitgud::git::DiffOptions DiffOptionsArg(lua_State* _pL, int _iArg)
        {
            gitgud::git::DiffOptions options;
            if (lua_istable(_pL, _iArg))
            {
                lua_getfield(_pL, _iArg, "ignoreWhitespace");
                options.m_bIgnoreWhitespace = lua_toboolean(_pL, -1) != 0;
                lua_pop(_pL, 1);
                lua_getfield(_pL, _iArg, "context");
                if (lua_isinteger(_pL, -1))
                {
                    options.m_iContextLines = static_cast<int>(lua_tointeger(_pL, -1));
                }
                lua_pop(_pL, 1);
                lua_getfield(_pL, _iArg, "path");
                if (lua_type(_pL, -1) == LUA_TSTRING)
                {
                    options.m_Paths.emplace_back(lua_tostring(_pL, -1));
                }
                lua_pop(_pL, 1);
            }
            return options;
        }

        // 1-based Lua indices -> 0-based.
        std::vector<std::size_t> IndexList(lua_State* _pL, int _iArg)
        {
            luaL_checktype(_pL, _iArg, LUA_TTABLE);
            std::vector<std::size_t> out;
            const lua_Integer n = luaL_len(_pL, _iArg);
            for (lua_Integer i = 1; i <= n; ++i)
            {
                lua_rawgeti(_pL, _iArg, i);
                const lua_Integer v = lua_tointeger(_pL, -1);
                if (v >= 1)
                {
                    out.push_back(static_cast<std::size_t>(v - 1));
                }
                lua_pop(_pL, 1);
            }
            return out;
        }

        void PushMergeResult(lua_State* _pL, const gitgud::git::MergeResult& _M);

        const char* MergeKindName(gitgud::git::MergeResult::Kind _K)
        {
            using Kind = gitgud::git::MergeResult::Kind;
            switch (_K)
            {
            case Kind::UpToDate:
                return "uptodate";
            case Kind::FastForward:
                return "fastforward";
            case Kind::Merged:
                return "merged";
            case Kind::Conflicts:
                return "conflicts";
            }
            return "unknown";
        }

        void PushMergeResult(lua_State* _pL, const gitgud::git::MergeResult& _M)
        {
            lua_newtable(_pL);
            SetField(_pL, "kind", MergeKindName(_M.m_Kind));
            SetField(_pL, "message", _M.m_Message);
            PushStringArray(_pL, _M.m_ConflictedPaths);
            lua_setfield(_pL, -2, "conflicts");
        }

        void PushRebaseResult(lua_State* _pL, const gitgud::git::RebaseResult& _R)
        {
            using Kind = gitgud::git::RebaseResult::Kind;
            lua_newtable(_pL);
            const char* szkind = _R.m_Kind == Kind::Done
                                     ? "done"
                                     : (_R.m_Kind == Kind::Conflicts ? "conflicts" : "uptodate");
            SetField(_pL, "kind", szkind);
            SetField(_pL, "message", _R.m_Message);
            PushStringArray(_pL, _R.m_ConflictedPaths);
            lua_setfield(_pL, -2, "conflicts");
        }

        void PushCommitInfo(lua_State* _pL, const gitgud::git::CommitInfo& _C)
        {
            lua_newtable(_pL);
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

        // Used when discarding: new files go to the recycle bin, not oblivion.
        bool TrashFile(const std::string& _AbsPath)
        {
            return gitgud::platform::MoveToTrash(_AbsPath);
        }

        // ---- repo state ------------------------------------------------------------

        int LIsOpen(lua_State* _pL)
        {
            auto* prepo = Self(_pL)->Repository();
            lua_pushboolean(_pL, prepo && prepo->IsOpen());
            return 1;
        }

        int LRepoPath(lua_State* _pL)
        {
            auto* prepo = Self(_pL)->Repository();
            const std::string p = prepo ? prepo->WorkDir() : "";
            lua_pushlstring(_pL, p.data(), p.size());
            return 1;
        }

        int LRepoState(lua_State* _pL)
        {
            using gitgud::git::RepoState;
            auto* prepo = Self(_pL)->Repository();
            const char* szstate = "none";
            if (prepo)
            {
                try
                {
                    switch (prepo->State())
                    {
                    case RepoState::None:
                        szstate = "none";
                        break;
                    case RepoState::Merge:
                        szstate = "merge";
                        break;
                    case RepoState::Rebase:
                        szstate = "rebase";
                        break;
                    case RepoState::CherryPick:
                        szstate = "cherrypick";
                        break;
                    case RepoState::Revert:
                        szstate = "revert";
                        break;
                    case RepoState::Other:
                        szstate = "other";
                        break;
                    }
                }
                catch (const GitError&)
                {
                }
            }
            lua_pushstring(_pL, szstate);
            return 1;
        }

        int LStatus(lua_State* _pL)
        {
            return RepoQuery(_pL, "status",
                [&](Repository& _R)
                {
                    const auto entries = _R.Status();
                    lua_createtable(_pL, static_cast<int>(entries.size()), 0);
                    int idx = 1;
                    for (const auto& e : entries)
                    {
                        lua_createtable(_pL, 0, 4);
                        SetField(_pL, "path", e.m_Path);
                        SetField(_pL, "staged", e.m_bStaged);
                        SetField(_pL, "unstaged", e.m_bUnstaged);
                        SetField(_pL, "code", std::string(1, e.m_cCode));
                        lua_rawseti(_pL, -2, idx++);
                    }
                    return 1;
                });
        }

        // gitgud.diff(path, which, options) — which: false/nil = unstaged, true or
        // "staged" = staged, "head" = both combined. options: {ignoreWhitespace,
        // context}.
        int LDiff(lua_State* _pL)
        {
            auto* prepo = Self(_pL)->Repository();
            const char* szpath = luaL_checkstring(_pL, 1);
            auto target = gitgud::git::DiffTarget::Unstaged;
            if (lua_type(_pL, 2) == LUA_TSTRING)
            {
                const std::string which = lua_tostring(_pL, 2);
                if (which == "head")
                {
                    target = gitgud::git::DiffTarget::Head;
                }
                else if (which == "staged")
                {
                    target = gitgud::git::DiffTarget::Staged;
                }
            }
            else if (lua_toboolean(_pL, 2))
            {
                target = gitgud::git::DiffTarget::Staged;
            }
            const auto options = DiffOptionsArg(_pL, 3);
            if (!prepo)
            {
                return NoRepo(_pL);
            }
            try
            {
                PushFileDiff(_pL, prepo->DiffFile(szpath, target, options));
                return 1;
            }
            catch (const GitError& e)
            {
                return FailWith(_pL, e.what());
            }
        }

        int LAheadBehind(lua_State* _pL)
        {
            return RepoQuery(_pL, "aheadBehind",
                [&](Repository& _R)
                {
                    const auto ab = _R.GetAheadBehind();
                    lua_newtable(_pL);
                    SetField(_pL, "ahead", static_cast<lua_Integer>(ab.m_Ahead));
                    SetField(_pL, "behind", static_cast<lua_Integer>(ab.m_Behind));
                    SetField(_pL, "hasUpstream", ab.m_bHasUpstream);
                    SetField(_pL, "upstream", ab.m_Upstream);
                    SetField(_pL, "upstreamRemote", ab.m_UpstreamRemote);
                    return 1;
                });
        }

        // gitgud.compareBranch(ref) -> {ahead, behind} of HEAD relative to ref.
        int LCompareBranch(lua_State* _pL)
        {
            const std::string ref = luaL_checkstring(_pL, 1);
            return RepoQuery(_pL, "compareBranch",
                [&](Repository& _R)
                {
                    const auto ab = _R.CompareWith(ref);
                    lua_newtable(_pL);
                    SetField(_pL, "ahead", static_cast<lua_Integer>(ab.m_Ahead));
                    SetField(_pL, "behind", static_cast<lua_Integer>(ab.m_Behind));
                    return 1;
                });
        }

        // ---- staging -----------------------------------------------------------------

        // gitgud.stage(path | {paths})
        int LStage(lua_State* _pL)
        {
            const auto paths = StringList(_pL, 1);
            return RepoAction(_pL, [&](Repository& _R) { _R.Stage(paths); });
        }

        int LUnstage(lua_State* _pL)
        {
            const auto paths = StringList(_pL, 1);
            return RepoAction(_pL, [&](Repository& _R) { _R.Unstage(paths); });
        }

        int LStageHunk(lua_State* _pL)
        {
            const std::string path = luaL_checkstring(_pL, 1);
            const lua_Integer hunk = luaL_checkinteger(_pL, 2); // 1-based in Lua
            return RepoAction(_pL,
                [&](Repository& _R) { _R.StageHunk(path, static_cast<std::size_t>(hunk - 1)); });
        }

        int LUnstageHunk(lua_State* _pL)
        {
            const std::string path = luaL_checkstring(_pL, 1);
            const lua_Integer hunk = luaL_checkinteger(_pL, 2);
            return RepoAction(_pL,
                [&](Repository& _R) { _R.UnstageHunk(path, static_cast<std::size_t>(hunk - 1)); });
        }

        // gitgud.stagedLines(path) -> 1-based flat indices into diff(path, "head")
        int LStagedLines(lua_State* _pL)
        {
            const std::string path = luaL_checkstring(_pL, 1);
            return RepoQuery(_pL, "stagedLines",
                [&](Repository& _R)
                {
                    const auto lines = _R.StagedLines(path);
                    lua_createtable(_pL, static_cast<int>(lines.size()), 0);
                    int idx = 1;
                    for (std::size_t i : lines)
                    {
                        lua_pushinteger(_pL, static_cast<lua_Integer>(i + 1));
                        lua_rawseti(_pL, -2, idx++);
                    }
                    return 1;
                });
        }

        // gitgud.setStagedLines(path, {indices}, lineCount)
        int LSetStagedLines(lua_State* _pL)
        {
            const std::string path = luaL_checkstring(_pL, 1);
            const auto lines = IndexList(_pL, 2);
            const auto count = static_cast<std::size_t>(luaL_checkinteger(_pL, 3));
            return RepoAction(_pL, [&](Repository& _R) { _R.SetStagedLines(path, lines, count); });
        }

        // gitgud.discardLines(path, {indices}, lineCount)
        int LDiscardLines(lua_State* _pL)
        {
            const std::string path = luaL_checkstring(_pL, 1);
            const auto lines = IndexList(_pL, 2);
            const auto count = static_cast<std::size_t>(luaL_checkinteger(_pL, 3));
            return RepoAction(
                _pL, [&](Repository& _R) { _R.DiscardLines(path, lines, count, TrashFile); });
        }

        // gitgud.discard(path | {paths}) — new files go to the recycle bin.
        int LDiscard(lua_State* _pL)
        {
            const auto paths = StringList(_pL, 1);
            return RepoAction(_pL, [&](Repository& _R) { _R.DiscardChanges(paths, TrashFile); });
        }

        int LIgnore(lua_State* _pL)
        {
            const std::string pattern = luaL_checkstring(_pL, 1);
            return RepoAction(_pL, [&](Repository& _R) { _R.AddToGitignore(pattern); });
        }

        // ---- commits -------------------------------------------------------------------

        int LCommit(lua_State* _pL)
        {
            const std::string message = luaL_checkstring(_pL, 1);
            return RepoStringAction(_pL, [&](Repository& _R) { return _R.Commit(message); });
        }

        int LAmend(lua_State* _pL)
        {
            const std::string message = luaL_checkstring(_pL, 1);
            return RepoStringAction(_pL, [&](Repository& _R) { return _R.AmendCommit(message); });
        }

        // gitgud.undoCommit() -> the undone commit's message
        int LUndoCommit(lua_State* _pL)
        {
            return RepoStringAction(_pL, [&](Repository& _R) { return _R.UndoLastCommit(); });
        }

        int LRevert(lua_State* _pL)
        {
            const std::string oid = luaL_checkstring(_pL, 1);
            return RepoStringAction(_pL, [&](Repository& _R) { return _R.Revert(oid); });
        }

        int LCherryPick(lua_State* _pL)
        {
            const std::string oid = luaL_checkstring(_pL, 1);
            return RepoStringAction(_pL, [&](Repository& _R) { return _R.CherryPick(oid); });
        }

        // gitgud.resetTo(oid, "soft" | "mixed" | "hard")
        int LResetTo(lua_State* _pL)
        {
            const std::string oid = luaL_checkstring(_pL, 1);
            const std::string mode = luaL_optstring(_pL, 2, "mixed");
            auto kind = gitgud::git::ResetMode::Mixed;
            if (mode == "soft")
            {
                kind = gitgud::git::ResetMode::Soft;
            }
            else if (mode == "hard")
            {
                kind = gitgud::git::ResetMode::Hard;
            }
            return RepoAction(_pL, [&](Repository& _R) { _R.ResetTo(oid, kind); });
        }

        // ---- branches ------------------------------------------------------------------

        int LBranches(lua_State* _pL)
        {
            return RepoQuery(_pL, "branches",
                [&](Repository& _R)
                {
                    const auto branches = _R.Branches();
                    lua_createtable(_pL, static_cast<int>(branches.size()), 0);
                    int idx = 1;
                    for (const auto& b : branches)
                    {
                        lua_createtable(_pL, 0, 8);
                        SetField(_pL, "name", b.m_Name);
                        SetField(_pL, "isHead", b.m_bIsHead);
                        SetField(_pL, "isRemote", b.m_bIsRemote);
                        SetField(_pL, "upstream", b.m_Upstream);
                        SetField(_pL, "oid", b.m_TargetOid);
                        SetField(_pL, "time", static_cast<lua_Integer>(b.m_TimeUtc));
                        SetField(_pL, "ahead", static_cast<lua_Integer>(b.m_Ahead));
                        SetField(_pL, "behind", static_cast<lua_Integer>(b.m_Behind));
                        lua_rawseti(_pL, -2, idx++);
                    }
                    return 1;
                });
        }

        int LCurrentBranch(lua_State* _pL)
        {
            auto* prepo = Self(_pL)->Repository();
            std::string name;
            if (prepo)
            {
                try
                {
                    name = prepo->CurrentBranch();
                }
                catch (const GitError&)
                {
                }
            }
            lua_pushlstring(_pL, name.data(), name.size());
            return 1;
        }

        // gitgud.createBranch(name, startPoint?)
        int LCreateBranch(lua_State* _pL)
        {
            const std::string name = luaL_checkstring(_pL, 1);
            const std::string start = luaL_optstring(_pL, 2, "");
            return RepoAction(_pL,
                [&](Repository& _R)
                {
                    if (start.empty())
                    {
                        _R.CreateBranch(name);
                    }
                    else
                    {
                        _R.CreateBranch(name, start);
                    }
                });
        }

        int LCheckout(lua_State* _pL)
        {
            const std::string name = luaL_checkstring(_pL, 1);
            return RepoAction(_pL, [&](Repository& _R) { _R.Checkout(name); });
        }

        int LCheckoutCommit(lua_State* _pL)
        {
            const std::string oid = luaL_checkstring(_pL, 1);
            return RepoAction(_pL, [&](Repository& _R) { _R.CheckoutCommit(oid); });
        }

        int LDeleteBranch(lua_State* _pL)
        {
            const std::string name = luaL_checkstring(_pL, 1);
            return RepoAction(_pL, [&](Repository& _R) { _R.DeleteBranch(name); });
        }

        int LRenameBranch(lua_State* _pL)
        {
            const std::string oldName = luaL_checkstring(_pL, 1);
            const std::string newName = luaL_checkstring(_pL, 2);
            return RepoAction(_pL, [&](Repository& _R) { _R.RenameBranch(oldName, newName); });
        }

        // ---- history -------------------------------------------------------------------

        // gitgud.history(max) or gitgud.history({max, skip, from, hide})
        int LHistory(lua_State* _pL)
        {
            gitgud::git::LogQuery query;
            if (lua_istable(_pL, 1))
            {
                lua_getfield(_pL, 1, "max");
                query.m_MaxCount = static_cast<std::size_t>(luaL_optinteger(_pL, -1, 200));
                lua_getfield(_pL, 1, "skip");
                query.m_Skip = static_cast<std::size_t>(luaL_optinteger(_pL, -1, 0));
                lua_getfield(_pL, 1, "from");
                query.m_From = luaL_optstring(_pL, -1, "");
                lua_getfield(_pL, 1, "hide");
                query.m_Hide = luaL_optstring(_pL, -1, "");
                lua_pop(_pL, 4);
            }
            else
            {
                query.m_MaxCount = static_cast<std::size_t>(luaL_optinteger(_pL, 1, 200));
            }

            return RepoQuery(_pL, "history",
                [&](Repository& _R)
                {
                    const auto commits = _R.Log(query);
                    lua_createtable(_pL, static_cast<int>(commits.size()), 0);
                    int idx = 1;
                    for (const auto& c : commits)
                    {
                        PushCommitInfo(_pL, c);
                        lua_rawseti(_pL, -2, idx++);
                    }
                    return 1;
                });
        }

        int LCommitDiff(lua_State* _pL)
        {
            auto* prepo = Self(_pL)->Repository();
            const char* szoid = luaL_checkstring(_pL, 1);
            const auto options = DiffOptionsArg(_pL, 2);
            if (!prepo)
            {
                return NoRepo(_pL);
            }
            try
            {
                const auto files = prepo->DiffCommit(szoid, options);
                lua_createtable(_pL, static_cast<int>(files.size()), 0);
                int idx = 1;
                for (const auto& f : files)
                {
                    PushFileDiff(_pL, f);
                    lua_rawseti(_pL, -2, idx++);
                }
                return 1;
            }
            catch (const GitError& e)
            {
                return FailWith(_pL, e.what());
            }
        }

        // gitgud.refLabels() -> {{oid, name, kind}} ; kind: "branch" | "remote" |
        // "tag" | "head"
        int LRefLabels(lua_State* _pL)
        {
            return RepoQuery(_pL, "refLabels",
                [&](Repository& _R)
                {
                    const auto labels = _R.RefLabels();
                    lua_createtable(_pL, static_cast<int>(labels.size()), 0);
                    int idx = 1;
                    for (const auto& l : labels)
                    {
                        lua_createtable(_pL, 0, 3);
                        SetField(_pL, "oid", l.m_Oid);
                        SetField(_pL, "name", l.m_Name);
                        const char* szkind = l.m_cKind == 'b'   ? "branch"
                                             : l.m_cKind == 'r' ? "remote"
                                             : l.m_cKind == 't' ? "tag"
                                                                : "head";
                        SetField(_pL, "kind", szkind);
                        lua_rawseti(_pL, -2, idx++);
                    }
                    return 1;
                });
        }

        // ---- tags ----------------------------------------------------------------------

        int LTags(lua_State* _pL)
        {
            return RepoQuery(_pL, "tags",
                [&](Repository& _R)
                {
                    const auto tags = _R.Tags();
                    lua_createtable(_pL, static_cast<int>(tags.size()), 0);
                    int idx = 1;
                    for (const auto& t : tags)
                    {
                        lua_createtable(_pL, 0, 3);
                        SetField(_pL, "name", t.m_Name);
                        SetField(_pL, "oid", t.m_TargetOid);
                        SetField(_pL, "message", t.m_Message);
                        lua_rawseti(_pL, -2, idx++);
                    }
                    return 1;
                });
        }

        // gitgud.createTag(name, target?, message?)
        int LCreateTag(lua_State* _pL)
        {
            const std::string name = luaL_checkstring(_pL, 1);
            const std::string target = luaL_optstring(_pL, 2, "HEAD");
            const std::string message = luaL_optstring(_pL, 3, "");
            return RepoAction(_pL, [&](Repository& _R) { _R.CreateTag(name, target, message); });
        }

        int LDeleteTag(lua_State* _pL)
        {
            const std::string name = luaL_checkstring(_pL, 1);
            return RepoAction(_pL, [&](Repository& _R) { _R.DeleteTag(name); });
        }

        // ---- remotes / stash -----------------------------------------------------------

        int LRemotes(lua_State* _pL)
        {
            return RepoQuery(_pL, "remotes",
                [&](Repository& _R)
                {
                    const auto remotes = _R.Remotes();
                    lua_createtable(_pL, static_cast<int>(remotes.size()), 0);
                    int idx = 1;
                    for (const auto& r : remotes)
                    {
                        lua_createtable(_pL, 0, 2);
                        SetField(_pL, "name", r.m_Name);
                        SetField(_pL, "url", r.m_Url);
                        lua_rawseti(_pL, -2, idx++);
                    }
                    return 1;
                });
        }

        int LAddRemote(lua_State* _pL)
        {
            const std::string name = luaL_checkstring(_pL, 1);
            const std::string url = luaL_checkstring(_pL, 2);
            return RepoAction(_pL, [&](Repository& _R) { _R.AddRemote(name, url); });
        }

        int LRemoveRemote(lua_State* _pL)
        {
            const std::string name = luaL_checkstring(_pL, 1);
            return RepoAction(_pL, [&](Repository& _R) { _R.RemoveRemote(name); });
        }

        int LSetRemoteUrl(lua_State* _pL)
        {
            const std::string name = luaL_checkstring(_pL, 1);
            const std::string url = luaL_checkstring(_pL, 2);
            return RepoAction(_pL, [&](Repository& _R) { _R.SetRemoteUrl(name, url); });
        }

        int LRenameRemote(lua_State* _pL)
        {
            const std::string name = luaL_checkstring(_pL, 1);
            const std::string newName = luaL_checkstring(_pL, 2);
            return RepoAction(_pL, [&](Repository& _R) { _R.RenameRemote(name, newName); });
        }

        // gitgud.setUpstream(branch, "remote/branch"), or nil/"" to stop tracking
        int LSetUpstream(lua_State* _pL)
        {
            const std::string branch = luaL_checkstring(_pL, 1);
            const std::string upstream = luaL_optstring(_pL, 2, "");
            return RepoAction(_pL, [&](Repository& _R) { _R.SetUpstream(branch, upstream); });
        }

        int LStashList(lua_State* _pL)
        {
            return RepoQuery(_pL, "stashList",
                [&](Repository& _R)
                {
                    const auto stashes = _R.StashList();
                    lua_createtable(_pL, static_cast<int>(stashes.size()), 0);
                    int idx = 1;
                    for (const auto& s : stashes)
                    {
                        lua_createtable(_pL, 0, 3);
                        SetField(_pL, "index", static_cast<lua_Integer>(s.m_Index + 1));
                        SetField(_pL, "message", s.m_Message);
                        SetField(_pL, "oid", s.m_Oid);
                        lua_rawseti(_pL, -2, idx++);
                    }
                    return 1;
                });
        }

        int LStashSave(lua_State* _pL)
        {
            const std::string message = luaL_optstring(_pL, 1, "");
            return RepoAction(_pL, [&](Repository& _R) { _R.StashSave(message); });
        }

        int LStashApply(lua_State* _pL)
        {
            const lua_Integer i = luaL_optinteger(_pL, 1, 1);
            return RepoAction(
                _pL, [&](Repository& _R) { _R.StashApply(static_cast<std::size_t>(i - 1)); });
        }

        int LStashPop(lua_State* _pL)
        {
            const lua_Integer i = luaL_optinteger(_pL, 1, 1);
            return RepoAction(
                _pL, [&](Repository& _R) { _R.StashPop(static_cast<std::size_t>(i - 1)); });
        }

        int LStashDrop(lua_State* _pL)
        {
            const lua_Integer i = luaL_optinteger(_pL, 1, 1);
            return RepoAction(
                _pL, [&](Repository& _R) { _R.StashDrop(static_cast<std::size_t>(i - 1)); });
        }

        // gitgud.stashDiff(index) -> array of file diffs
        int LStashDiff(lua_State* _pL)
        {
            const lua_Integer i = luaL_optinteger(_pL, 1, 1);
            auto* prepo = Self(_pL)->Repository();
            if (!prepo)
            {
                return NoRepo(_pL);
            }
            try
            {
                const auto files = prepo->StashDiff(static_cast<std::size_t>(i - 1));
                lua_createtable(_pL, static_cast<int>(files.size()), 0);
                int idx = 1;
                for (const auto& f : files)
                {
                    PushFileDiff(_pL, f);
                    lua_rawseti(_pL, -2, idx++);
                }
                return 1;
            }
            catch (const GitError& e)
            {
                return FailWith(_pL, e.what());
            }
        }

        // ---- merge / rebase / conflicts ------------------------------------------------

        template <typename Fn> int MergeLike(lua_State* _pL, Fn&& _Fn)
        {
            LuaEngine* pengine = Self(_pL);
            auto* prepo = pengine->Repository();
            if (!prepo)
            {
                return NoRepo(_pL);
            }
            try
            {
                const auto result = _Fn(*prepo);
                PublishStatusChanged(pengine);
                PushMergeResult(_pL, result);
                return 1;
            }
            catch (const GitError& e)
            {
                return FailWith(_pL, e.what());
            }
        }

        int LMerge(lua_State* _pL)
        {
            const std::string branch = luaL_checkstring(_pL, 1);
            return MergeLike(_pL, [&](Repository& _R) { return _R.Merge(branch); });
        }

        int LSquashMerge(lua_State* _pL)
        {
            const std::string branch = luaL_checkstring(_pL, 1);
            return MergeLike(_pL, [&](Repository& _R) { return _R.SquashMerge(branch); });
        }

        template <typename Fn> int RebaseLike(lua_State* _pL, Fn&& _Fn)
        {
            LuaEngine* pengine = Self(_pL);
            auto* prepo = pengine->Repository();
            if (!prepo)
            {
                return NoRepo(_pL);
            }
            try
            {
                const auto result = _Fn(*prepo);
                PublishStatusChanged(pengine);
                PushRebaseResult(_pL, result);
                return 1;
            }
            catch (const GitError& e)
            {
                PublishStatusChanged(pengine);
                return FailWith(_pL, e.what());
            }
        }

        int LRebase(lua_State* _pL)
        {
            const std::string upstream = luaL_checkstring(_pL, 1);
            return RebaseLike(_pL, [&](Repository& _R) { return _R.Rebase(upstream); });
        }

        int LContinueRebase(lua_State* _pL)
        {
            return RebaseLike(_pL, [&](Repository& _R) { return _R.ContinueRebase(); });
        }

        int LConflicts(lua_State* _pL)
        {
            return RepoQuery(_pL, "conflicts",
                [&](Repository& _R)
                {
                    PushStringArray(_pL, _R.ConflictedPaths());
                    return 1;
                });
        }

        // gitgud.resolveConflict(path, "ours" | "theirs")
        int LResolveConflict(lua_State* _pL)
        {
            const std::string path = luaL_checkstring(_pL, 1);
            const std::string side = luaL_checkstring(_pL, 2);
            return RepoAction(
                _pL, [&](Repository& _R) { _R.ResolveConflict(path, side == "ours"); });
        }

        int LAbortMerge(lua_State* _pL)
        {
            return RepoAction(_pL, [](Repository& _R) { _R.AbortMerge(); });
        }

        int LAbortOperation(lua_State* _pL)
        {
            return RepoAction(_pL, [](Repository& _R) { _R.AbortOperation(); });
        }

        // ---- config --------------------------------------------------------------------

        int LConfig(lua_State* _pL)
        {
            const std::string key = luaL_checkstring(_pL, 1);
            auto* prepo = Self(_pL)->Repository();
            std::string value;
            try
            {
                value = prepo ? prepo->GetConfig(key) : Repository::GetGlobalConfig(key);
            }
            catch (const GitError&)
            {
            }
            lua_pushlstring(_pL, value.data(), value.size());
            return 1;
        }

        int LSetConfig(lua_State* _pL)
        {
            const std::string key = luaL_checkstring(_pL, 1);
            const std::string value = luaL_checkstring(_pL, 2);
            return RepoAction(_pL, [&](Repository& _R) { _R.SetConfig(key, value); });
        }

        int LGlobalConfig(lua_State* _pL)
        {
            const std::string key = luaL_checkstring(_pL, 1);
            const std::string value = Repository::GetGlobalConfig(key);
            lua_pushlstring(_pL, value.data(), value.size());
            return 1;
        }

        int LSetGlobalConfig(lua_State* _pL)
        {
            const std::string key = luaL_checkstring(_pL, 1);
            const std::string value = luaL_checkstring(_pL, 2);
            try
            {
                Repository::SetGlobalConfig(key, value);
                lua_pushboolean(_pL, 1);
                return 1;
            }
            catch (const GitError& e)
            {
                return FailWith(_pL, e.what());
            }
        }

        // ---- async network ops ---------------------------------------------------------

        // The CredentialProvider a worker job uses: read the (thread-safe, OS-backed)
        // store; when nothing is stored, tell the UI so it can prompt, and fail.
        gitgud::git::CredentialProvider MakeProvider(
            gitgud::platform::ICredentialStore* _pStore, gitgud::app::EventBus* _pBus)
        {
            return [_pStore, _pBus](const std::string& _Url, const std::string& _UserFromUrl,
                       std::string& _OutUser, std::string& _OutPass) -> bool
            {
                // SSH key passphrases are stored under "ssh-key:<key path>".
                const bool bsshKey = _Url.rfind("ssh-key:", 0) == 0;
                const std::string host = bsshKey ? _Url : gitgud::platform::HostFromUrl(_Url);
                if (_pStore)
                {
                    gitgud::platform::Credential cred;
                    if (_pStore->Get(host, cred))
                    {
                        _OutUser = cred.m_Username.empty() ? _UserFromUrl : cred.m_Username;
                        _OutPass = cred.m_Password;
                        return true;
                    }
                }
                if (_pBus)
                {
                    _pBus->Publish({"credential.missing", host});
                }
                return false;
            };
        }

        // Is exactly this "host type key" line already in ~/.ssh/known_hosts?
        bool KnownHostsHasLine(const std::string& _Line)
        {
            const char* szhome = std::getenv("USERPROFILE");
            if (!szhome)
            {
                szhome = std::getenv("HOME");
            }
            if (!szhome)
            {
                return false;
            }
            std::ifstream in(std::filesystem::u8path(szhome) / ".ssh" / "known_hosts");
            std::string line;
            while (std::getline(in, line))
            {
                if (!line.empty() && line.back() == '\r')
                {
                    line.pop_back();
                }
                if (line == _Line)
                {
                    return true;
                }
            }
            return false;
        }

        // The HostKeyProvider a worker job uses: trust keys the user already
        // accepted (their known_hosts line); otherwise ask the UI, which calls
        // gitgud.trustHostKey and retries, and fail this attempt.
        gitgud::git::HostKeyProvider MakeHostKeyProvider(gitgud::app::EventBus* _pBus)
        {
            return [_pBus](const std::string& _Host, const std::string& _Fingerprint,
                       const std::string& _Line) -> bool
            {
                if (KnownHostsHasLine(_Line))
                {
                    return true;
                }
                if (_pBus)
                {
                    _pBus->Publish({"ssh.unknownHost", _Host + "\n" + _Fingerprint + "\n" + _Line});
                }
                return false;
            };
        }

        // Run `_Job(repo)` on a worker with its OWN repository handle; results
        // arrive as "<op>.done" / "<op>.error".
        int RunRemoteJob(
            lua_State* _pL, const std::string& _Op, std::function<std::string(Repository&)> _Job)
        {
            LuaEngine* pengine = Self(_pL);
            auto* prepo = pengine->Repository();
            auto* ptasks = pengine->TaskRunner();
            if (!prepo || !ptasks)
            {
                lua_pushboolean(_pL, 0);
                return 1;
            }
            const std::string path = prepo->Path();
            auto provider = MakeProvider(pengine->CredentialStore(), pengine->EventBus());
            auto hostKeys = MakeHostKeyProvider(pengine->EventBus());
            ptasks->Run(_Op,
                [path, provider, hostKeys, job = std::move(_Job)]() -> std::string
                {
                    Repository r = Repository::Open(path);
                    r.SetCredentialProvider(provider);
                    r.SetHostKeyProvider(hostKeys);
                    return job(r);
                });
            lua_pushboolean(_pL, 1);
            return 1;
        }

        int LFetch(lua_State* _pL)
        {
            const std::string remote = luaL_optstring(_pL, 1, "origin");
            return RunRemoteJob(_pL, "fetch",
                [remote](Repository& _R)
                {
                    _R.Fetch(remote);
                    return "Fetched " + remote;
                });
        }

        // gitgud.fetchAll() - every remote; done/error arrive as "fetch.*"
        int LFetchAll(lua_State* _pL)
        {
            return RunRemoteJob(_pL, "fetch",
                [](Repository& _R)
                {
                    const auto fetched = _R.FetchAll();
                    std::string names;
                    for (const auto& name : fetched)
                    {
                        names += (names.empty() ? "" : ", ") + name;
                    }
                    return fetched.empty() ? std::string("No remotes to fetch")
                                           : "Fetched " + names;
                });
        }

        // gitgud.push(remote, {force = bool, setUpstream = bool})
        int LPush(lua_State* _pL)
        {
            const std::string remote = luaL_optstring(_pL, 1, "origin");
            bool bforce = false;
            bool bsetUpstream = false;
            if (lua_istable(_pL, 2))
            {
                lua_getfield(_pL, 2, "force");
                bforce = lua_toboolean(_pL, -1) != 0;
                lua_pop(_pL, 1);
                lua_getfield(_pL, 2, "setUpstream");
                bsetUpstream = lua_toboolean(_pL, -1) != 0;
                lua_pop(_pL, 1);
            }
            return RunRemoteJob(_pL, "push",
                [remote, bforce, bsetUpstream](Repository& _R)
                {
                    _R.Push(remote, bforce, bsetUpstream);
                    return std::string(bforce ? "Force-pushed to " : "Pushed to ") + remote;
                });
        }

        int LPull(lua_State* _pL)
        {
            const std::string remote = luaL_optstring(_pL, 1, "origin");
            return RunRemoteJob(_pL, "pull",
                [remote](Repository& _R)
                {
                    // Encode the merge outcome as "kind|message" for Lua.
                    const auto result = _R.Pull(remote);
                    return std::string(MergeKindName(result.m_Kind)) + "|" + result.m_Message;
                });
        }

        int LPushTags(lua_State* _pL)
        {
            const std::string remote = luaL_optstring(_pL, 1, "origin");
            return RunRemoteJob(_pL, "pushTags",
                [remote](Repository& _R)
                {
                    _R.PushTags(remote);
                    return "Pushed tags to " + remote;
                });
        }

        // gitgud.pushBranch(remote, branch, {force, as}) -> pushBranch.* events
        int LPushBranch(lua_State* _pL)
        {
            const std::string remote = luaL_checkstring(_pL, 1);
            const std::string branch = luaL_checkstring(_pL, 2);
            bool bforce = false;
            std::string target;
            if (lua_istable(_pL, 3))
            {
                lua_getfield(_pL, 3, "force");
                bforce = lua_toboolean(_pL, -1) != 0;
                lua_pop(_pL, 1);
                lua_getfield(_pL, 3, "as");
                if (lua_isstring(_pL, -1))
                {
                    target = lua_tostring(_pL, -1);
                }
                lua_pop(_pL, 1);
            }
            return RunRemoteJob(_pL, "pushBranch",
                [remote, branch, target, bforce](Repository& _R)
                {
                    _R.PushBranch(remote, branch, target, bforce);
                    return branch + "|" + remote;
                });
        }

        int LDeleteRemoteBranch(lua_State* _pL)
        {
            const std::string remote = luaL_checkstring(_pL, 1);
            const std::string branch = luaL_checkstring(_pL, 2);
            return RunRemoteJob(_pL, "deleteRemoteBranch",
                [remote, branch](Repository& _R)
                {
                    _R.DeleteRemoteBranch(remote, branch);
                    return "Deleted " + remote + "/" + branch;
                });
        }

        // gitgud.updateSubmodule(name, init) - async: "updateSubmodule.done/.error"
        int LUpdateSubmodule(lua_State* _pL)
        {
            const std::string name = luaL_checkstring(_pL, 1);
            const bool binit = lua_isnoneornil(_pL, 2) || lua_toboolean(_pL, 2) != 0;
            return RunRemoteJob(_pL, "updateSubmodule",
                [name, binit](Repository& _R)
                {
                    _R.UpdateSubmodule(name, binit);
                    return "Updated submodule " + name;
                });
        }

        int LClone(lua_State* _pL)
        {
            LuaEngine* pengine = Self(_pL);
            const std::string url = luaL_checkstring(_pL, 1);
            const std::string path = luaL_checkstring(_pL, 2);
            auto* ptasks = pengine->TaskRunner();
            if (!ptasks)
            {
                lua_pushboolean(_pL, 0);
                return 1;
            }
            auto provider = MakeProvider(pengine->CredentialStore(), pengine->EventBus());
            auto hostKeys = MakeHostKeyProvider(pengine->EventBus());
            ptasks->Run("clone",
                [url, path, provider, hostKeys]() -> std::string
                {
                    Repository::Clone(url, path, provider, hostKeys);
                    return path; // "clone.done" detail = where it landed
                });
            lua_pushboolean(_pL, 1);
            return 1;
        }

        // ---- repo open/init (handled by main.cpp, which owns the Repository) ----------

        int LOpenRepo(lua_State* _pL)
        {
            const char* szpath = luaL_checkstring(_pL, 1);
            if (auto* pbus = Self(_pL)->EventBus())
            {
                pbus->Publish({"repo.openRequested", szpath});
            }
            return 0;
        }

        int LInitRepo(lua_State* _pL)
        {
            const char* szpath = luaL_checkstring(_pL, 1);
            if (auto* pbus = Self(_pL)->EventBus())
            {
                pbus->Publish({"repo.initRequested", szpath});
            }
            return 0;
        }

        int LCloseRepo(lua_State* _pL)
        {
            if (auto* pbus = Self(_pL)->EventBus())
            {
                pbus->Publish({"repo.closeRequested", ""});
            }
            return 0;
        }

        // ---- credentials ------------------------------------------------------------

        int LSetCredential(lua_State* _pL)
        {
            const std::string host = luaL_checkstring(_pL, 1);
            const std::string user = luaL_checkstring(_pL, 2);
            const std::string pass = luaL_checkstring(_pL, 3);
            auto* pstore = Self(_pL)->CredentialStore();
            lua_pushboolean(_pL, pstore && pstore->Set(host, {user, pass}));
            return 1;
        }

        int LHasCredential(lua_State* _pL)
        {
            const std::string host = luaL_checkstring(_pL, 1);
            auto* pstore = Self(_pL)->CredentialStore();
            gitgud::platform::Credential cred;
            lua_pushboolean(_pL, pstore && pstore->Get(host, cred));
            return 1;
        }

        int LEraseCredential(lua_State* _pL)
        {
            const std::string host = luaL_checkstring(_pL, 1);
            auto* pstore = Self(_pL)->CredentialStore();
            lua_pushboolean(_pL, pstore && pstore->Erase(host));
            return 1;
        }

        int LHostForRemote(lua_State* _pL)
        {
            const std::string name = luaL_optstring(_pL, 1, "origin");
            std::string host;
            if (auto* prepo = Self(_pL)->Repository())
            {
                try
                {
                    for (const auto& r : prepo->Remotes())
                    {
                        if (r.m_Name == name)
                        {
                            host = gitgud::platform::HostFromUrl(r.m_Url);
                            break;
                        }
                    }
                }
                catch (const GitError&)
                {
                }
            }
            lua_pushlstring(_pL, host.data(), host.size());
            return 1;
        }

    } // namespace

    std::vector<std::string> StringList(lua_State* _pL, int _iArg)
    {
        std::vector<std::string> out;
        if (lua_istable(_pL, _iArg))
        {
            const lua_Integer n = luaL_len(_pL, _iArg);
            for (lua_Integer i = 1; i <= n; ++i)
            {
                lua_rawgeti(_pL, _iArg, i);
                std::size_t len = 0;
                if (const char* sz = lua_tolstring(_pL, -1, &len))
                {
                    out.emplace_back(sz, len);
                }
                lua_pop(_pL, 1);
            }
            return out;
        }
        out.emplace_back(luaL_checkstring(_pL, _iArg));
        return out;
    }

    void PushStringArray(lua_State* _pL, const std::vector<std::string>& _Items)
    {
        lua_createtable(_pL, static_cast<int>(_Items.size()), 0);
        int idx = 1;
        for (const auto& item : _Items)
        {
            lua_pushlstring(_pL, item.data(), item.size());
            lua_rawseti(_pL, -2, idx++);
        }
    }

    void PushFileDiff(lua_State* _pL, const gitgud::git::FileDiff& _Diff)
    {
        lua_createtable(_pL, 0, 5);
        SetField(_pL, "path", _Diff.m_Path);
        SetField(_pL, "oldPath", _Diff.m_OldPath);
        SetField(_pL, "status", std::string(1, _Diff.m_cStatus));
        SetField(_pL, "binary", _Diff.m_bIsBinary);
        lua_createtable(_pL, static_cast<int>(_Diff.m_Hunks.size()), 0);
        int ihunk = 1;
        for (const auto& h : _Diff.m_Hunks)
        {
            lua_createtable(_pL, 0, 4);
            SetField(_pL, "header", h.m_Header);
            SetField(_pL, "oldStart", static_cast<lua_Integer>(h.m_iOldStart));
            SetField(_pL, "newStart", static_cast<lua_Integer>(h.m_iNewStart));
            lua_createtable(_pL, static_cast<int>(h.m_Lines.size()), 0);
            int iline = 1;
            for (const auto& ln : h.m_Lines)
            {
                lua_createtable(_pL, 0, 4);
                SetField(_pL, "origin", std::string(1, ln.m_cOrigin));
                SetField(_pL, "content", ln.m_Content);
                SetField(_pL, "oldLineno", static_cast<lua_Integer>(ln.m_iOldLineno));
                SetField(_pL, "newLineno", static_cast<lua_Integer>(ln.m_iNewLineno));
                lua_rawseti(_pL, -2, iline++);
            }
            lua_setfield(_pL, -2, "lines");
            lua_rawseti(_pL, -2, ihunk++);
        }
        lua_setfield(_pL, -2, "hunks");
    }

    void AddRepoBindings(std::vector<luaL_Reg>& _Out)
    {
        const luaL_Reg kFunctions[] = {
            // repo state
            {"isOpen", LIsOpen},
            {"repoPath", LRepoPath},
            {"repoState", LRepoState},
            {"status", LStatus},
            {"diff", LDiff},
            {"aheadBehind", LAheadBehind},
            {"compareBranch", LCompareBranch},
            // staging
            {"stage", LStage},
            {"unstage", LUnstage},
            {"stageHunk", LStageHunk},
            {"unstageHunk", LUnstageHunk},
            {"stagedLines", LStagedLines},
            {"setStagedLines", LSetStagedLines},
            {"discardLines", LDiscardLines},
            {"discard", LDiscard},
            {"ignore", LIgnore},
            // commits
            {"commit", LCommit},
            {"amend", LAmend},
            {"undoCommit", LUndoCommit},
            {"revert", LRevert},
            {"cherryPick", LCherryPick},
            {"resetTo", LResetTo},
            // branches
            {"branches", LBranches},
            {"currentBranch", LCurrentBranch},
            {"createBranch", LCreateBranch},
            {"checkout", LCheckout},
            {"checkoutCommit", LCheckoutCommit},
            {"deleteBranch", LDeleteBranch},
            {"renameBranch", LRenameBranch},
            // history + tags
            {"history", LHistory},
            {"commitDiff", LCommitDiff},
            {"refLabels", LRefLabels},
            {"tags", LTags},
            {"createTag", LCreateTag},
            {"deleteTag", LDeleteTag},
            // remotes / stash
            {"remotes", LRemotes},
            {"addRemote", LAddRemote},
            {"removeRemote", LRemoveRemote},
            {"setRemoteUrl", LSetRemoteUrl},
            {"renameRemote", LRenameRemote},
            {"setUpstream", LSetUpstream},
            {"stashList", LStashList},
            {"stashSave", LStashSave},
            {"stashApply", LStashApply},
            {"stashPop", LStashPop},
            {"stashDrop", LStashDrop},
            {"stashDiff", LStashDiff},
            // merge / rebase / conflicts
            {"merge", LMerge},
            {"squashMerge", LSquashMerge},
            {"rebase", LRebase},
            {"continueRebase", LContinueRebase},
            {"conflicts", LConflicts},
            {"resolveConflict", LResolveConflict},
            {"abortMerge", LAbortMerge},
            {"abortOperation", LAbortOperation},
            // config
            {"config", LConfig},
            {"setConfig", LSetConfig},
            {"globalConfig", LGlobalConfig},
            {"setGlobalConfig", LSetGlobalConfig},
            // async network
            {"fetch", LFetch},
            {"fetchAll", LFetchAll},
            {"push", LPush},
            {"pull", LPull},
            {"pushTags", LPushTags},
            {"deleteRemoteBranch", LDeleteRemoteBranch},
            {"pushBranch", LPushBranch},
            {"updateSubmodule", LUpdateSubmodule},
            {"clone", LClone},
            // repo lifecycle
            {"openRepo", LOpenRepo},
            {"initRepo", LInitRepo},
            {"closeRepo", LCloseRepo},
            // credentials
            {"setCredential", LSetCredential},
            {"hasCredential", LHasCredential},
            {"eraseCredential", LEraseCredential},
            {"hostForRemote", LHostForRemote},
        };
        _Out.insert(_Out.end(), std::begin(kFunctions), std::end(kFunctions));
    }

} // namespace gitgud::lua::bindings
