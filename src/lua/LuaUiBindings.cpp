// -----------------------------------------------------------------------------
// LuaUiBindings — the UI / platform half of the `gitgud` table: widgets,
// layouts, events, timers, images (the image diff), the desktop shell, and
// per-user config files.
// -----------------------------------------------------------------------------

#include "lua/LuaBindings.h"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

#include "app/EventBus.h"
#include "git/Repository.h"
#include "imaging/ImageDiff.h"
#include "platform/Shell.h"
#include "ui/IUiBackend.h"

namespace gitgud::lua::bindings
{

    namespace
    {

        namespace fs = std::filesystem;

        // ---- widgets -----------------------------------------------------------------

        int LSetText(lua_State* _pL)
        {
            const char* szid = luaL_checkstring(_pL, 1);
            const char* sztext = luaL_checkstring(_pL, 2);
            if (auto* pui = Self(_pL)->UiBackend())
            {
                pui->SetText(szid, sztext);
            }
            return 0;
        }

        int LGetText(lua_State* _pL)
        {
            const char* szid = luaL_checkstring(_pL, 1);
            std::string text;
            if (auto* pui = Self(_pL)->UiBackend())
            {
                text = pui->GetText(szid);
            }
            lua_pushlstring(_pL, text.data(), text.size());
            return 1;
        }

        int LSetList(lua_State* _pL)
        {
            const char* szid = luaL_checkstring(_pL, 1);
            luaL_checktype(_pL, 2, LUA_TTABLE);
            std::vector<std::string> items;
            const lua_Integer n = luaL_len(_pL, 2);
            items.reserve(static_cast<std::size_t>(n));
            for (lua_Integer i = 1; i <= n; ++i)
            {
                lua_rawgeti(_pL, 2, i);
                std::size_t len = 0;
                if (const char* szs = lua_tolstring(_pL, -1, &len))
                {
                    items.emplace_back(szs, len);
                }
                lua_pop(_pL, 1);
            }
            if (auto* pui = Self(_pL)->UiBackend())
            {
                pui->SetList(szid, items);
            }
            return 0;
        }

        // gitgud.setListItem(list, index, text) — 1-based
        int LSetListItem(lua_State* _pL)
        {
            const char* szid = luaL_checkstring(_pL, 1);
            const lua_Integer index = luaL_checkinteger(_pL, 2);
            const char* sztext = luaL_checkstring(_pL, 3);
            if (auto* pui = Self(_pL)->UiBackend())
            {
                pui->SetListItem(szid, static_cast<int>(index - 1), sztext);
            }
            return 0;
        }

        // gitgud.selectListItem(list, index | nil, scrollIntoView = true) —
        // 1-based; nil clears.
        int LSelectListItem(lua_State* _pL)
        {
            const char* szid = luaL_checkstring(_pL, 1);
            const lua_Integer index = luaL_optinteger(_pL, 2, 0);
            const bool bscroll = lua_isnoneornil(_pL, 3) || lua_toboolean(_pL, 3) != 0;
            if (auto* pui = Self(_pL)->UiBackend())
            {
                pui->SelectListItem(szid, static_cast<int>(index - 1), bscroll);
            }
            return 0;
        }

        int LGetScroll(lua_State* _pL)
        {
            const char* szid = luaL_checkstring(_pL, 1);
            float fpos = 0.0f;
            if (auto* pui = Self(_pL)->UiBackend())
            {
                fpos =
                    pui->GetScroll(szid, std::string(luaL_optstring(_pL, 2, "")) == "horizontal");
            }
            lua_pushnumber(_pL, fpos);
            return 1;
        }

        int LSetScroll(lua_State* _pL)
        {
            const char* szid = luaL_checkstring(_pL, 1);
            const lua_Number pos = luaL_checknumber(_pL, 2);
            if (auto* pui = Self(_pL)->UiBackend())
            {
                pui->SetScroll(szid, static_cast<float>(pos),
                    std::string(luaL_optstring(_pL, 3, "")) == "horizontal");
            }
            return 0;
        }

        template <void (gitgud::ui::IUiBackend::*Setter)(const std::string&, bool)>
        int BoolSetter(lua_State* _pL)
        {
            const char* szid = luaL_checkstring(_pL, 1);
            const bool bvalue = lua_toboolean(_pL, 2) != 0;
            if (auto* pui = Self(_pL)->UiBackend())
            {
                (pui->*Setter)(szid, bvalue);
            }
            return 0;
        }

        int LSetProperty(lua_State* _pL)
        {
            const char* szid = luaL_checkstring(_pL, 1);
            const char* szprop = luaL_checkstring(_pL, 2);
            const char* szvalue = luaL_checkstring(_pL, 3);
            if (auto* pui = Self(_pL)->UiBackend())
            {
                pui->SetProperty(szid, szprop, szvalue);
            }
            return 0;
        }

        int LGetProperty(lua_State* _pL)
        {
            const char* szid = luaL_checkstring(_pL, 1);
            const char* szprop = luaL_checkstring(_pL, 2);
            std::string value;
            if (auto* pui = Self(_pL)->UiBackend())
            {
                value = pui->GetProperty(szid, szprop);
            }
            lua_pushlstring(_pL, value.data(), value.size());
            return 1;
        }

        // gitgud.getRect(name) -> x, y, width, height (pixels), or nil
        int LGetRect(lua_State* _pL)
        {
            const char* szid = luaL_checkstring(_pL, 1);
            gitgud::ui::PixelRect rect;
            auto* pui = Self(_pL)->UiBackend();
            if (!pui || !pui->GetRect(szid, rect))
            {
                lua_pushnil(_pL);
                return 1;
            }
            lua_pushnumber(_pL, rect.m_fX);
            lua_pushnumber(_pL, rect.m_fY);
            lua_pushnumber(_pL, rect.m_fWidth);
            lua_pushnumber(_pL, rect.m_fHeight);
            return 4;
        }

        int LFocus(lua_State* _pL)
        {
            const char* szid = luaL_checkstring(_pL, 1);
            if (auto* pui = Self(_pL)->UiBackend())
            {
                pui->Focus(szid);
            }
            return 0;
        }

        // gitgud.textInputFocused() -> true while an editbox has keyboard focus
        int LTextInputFocused(lua_State* _pL)
        {
            auto* pui = Self(_pL)->UiBackend();
            lua_pushboolean(_pL, pui && pui->IsTextInputFocused());
            return 1;
        }

        int LBringToFront(lua_State* _pL)
        {
            const char* szid = luaL_checkstring(_pL, 1);
            if (auto* pui = Self(_pL)->UiBackend())
            {
                pui->BringToFront(szid);
            }
            return 0;
        }

        // gitgud.createWindow(type, name, parent) -> true on success
        int LCreateWindow(lua_State* _pL)
        {
            const char* sztype = luaL_checkstring(_pL, 1);
            const char* szid = luaL_checkstring(_pL, 2);
            const char* szparent = luaL_checkstring(_pL, 3);
            bool bok = false;
            if (auto* pui = Self(_pL)->UiBackend())
            {
                bok = pui->CreateWidget(sztype, szid, szparent);
            }
            lua_pushboolean(_pL, bok);
            return 1;
        }

        int LDestroyWindow(lua_State* _pL)
        {
            const char* szid = luaL_checkstring(_pL, 1);
            if (auto* pui = Self(_pL)->UiBackend())
            {
                pui->DestroyWidget(szid);
            }
            return 0;
        }

        // gitgud.loadLayout(file, parent) — file relative to resources/layouts.
        int LLoadLayout(lua_State* _pL)
        {
            const char* szfile = luaL_checkstring(_pL, 1);
            const char* szparent = luaL_optstring(_pL, 2, "Root");
            bool bok = false;
            if (auto* pui = Self(_pL)->UiBackend())
            {
                bok = pui->LoadLayoutInto(szfile, szparent);
            }
            lua_pushboolean(_pL, bok);
            return 1;
        }

        int LSuspendLayout(lua_State* _pL)
        {
            const char* szid = luaL_checkstring(_pL, 1);
            const bool bsuspended = lua_toboolean(_pL, 2) != 0;
            if (auto* pui = Self(_pL)->UiBackend())
            {
                pui->SuspendLayout(szid, bsuspended);
            }
            return 0;
        }

        int LLinkScroll(lua_State* _pL)
        {
            const char* sza = luaL_checkstring(_pL, 1);
            const char* szb = luaL_checkstring(_pL, 2);
            if (auto* pui = Self(_pL)->UiBackend())
            {
                pui->LinkScroll(sza, szb);
            }
            return 0;
        }

        int LGetSelectedIndex(lua_State* _pL)
        {
            const char* szid = luaL_checkstring(_pL, 1);
            int index = -1;
            if (auto* pui = Self(_pL)->UiBackend())
            {
                index = pui->GetSelectedIndex(szid);
            }
            if (index < 0)
            {
                lua_pushnil(_pL);
            }
            else
            {
                lua_pushinteger(_pL, index + 1);
            }
            return 1;
        }

        // ---- images -------------------------------------------------------------------

        int LIsImage(lua_State* _pL)
        {
            lua_pushboolean(_pL, gitgud::imaging::IsImagePath(luaL_checkstring(_pL, 1)));
            return 1;
        }

        // gitgud.imageDiff(path, beforeRev, afterRev) — decode both versions and
        // publish images "GitgudDiff/Before", "/After", "/Difference", "/Onion"
        // (see ImageDiff.h). Revisions: "workdir", "index", "head", "<oid>",
        // "<oid>^". Returns {width, height, beforeWidth, beforeHeight,
        // afterWidth, afterHeight, hasBefore, hasAfter, changed, total} or
        // (nil, message).
        int LImageDiff(lua_State* _pL)
        {
            LuaEngine* pengine = Self(_pL);
            const std::string path = luaL_checkstring(_pL, 1);
            const std::string beforeRev = luaL_checkstring(_pL, 2);
            const std::string afterRev = luaL_checkstring(_pL, 3);
            const lua_Integer highlight = luaL_optinteger(_pL, 4, 0xFF5EC4);

            auto* prepo = pengine->Repository();
            auto* pui = pengine->UiBackend();
            if (!prepo)
            {
                return NoRepo(_pL);
            }

            gitgud::imaging::Image before;
            gitgud::imaging::Image after;
            std::string error;
            try
            {
                std::string bytes;
                if (prepo->ReadFileVersion(path, beforeRev, bytes) &&
                    !gitgud::imaging::Decode(bytes, before, error))
                {
                    return FailWith(_pL, "previous version: " + error);
                }
                bytes.clear();
                if (prepo->ReadFileVersion(path, afterRev, bytes) &&
                    !gitgud::imaging::Decode(bytes, after, error))
                {
                    return FailWith(_pL, "new version: " + error);
                }
            }
            catch (const gitgud::git::GitError& e)
            {
                return FailWith(_pL, e.what());
            }
            if (before.Empty() && after.Empty())
            {
                return FailWith(_pL, "neither version could be read");
            }

            const auto cmp =
                gitgud::imaging::Compare(before, after, static_cast<std::uint32_t>(highlight));
            if (pui)
            {
                const auto define = [&](const char* _szName, const gitgud::imaging::Image& _Img)
                {
                    pui->DefineImage(_szName, _Img.m_iWidth, _Img.m_iHeight, _Img.m_Rgba);
                };
                define("GitgudDiff/Before", cmp.m_Before);
                define("GitgudDiff/After", cmp.m_After);
                define("GitgudDiff/Difference", cmp.m_Difference);
                define("GitgudDiff/Onion", cmp.m_Onion);
            }

            lua_newtable(_pL);
            SetField(_pL, "width", static_cast<lua_Integer>(cmp.m_Difference.m_iWidth));
            SetField(_pL, "height", static_cast<lua_Integer>(cmp.m_Difference.m_iHeight));
            SetField(_pL, "beforeWidth", static_cast<lua_Integer>(before.m_iWidth));
            SetField(_pL, "beforeHeight", static_cast<lua_Integer>(before.m_iHeight));
            SetField(_pL, "afterWidth", static_cast<lua_Integer>(after.m_iWidth));
            SetField(_pL, "afterHeight", static_cast<lua_Integer>(after.m_iHeight));
            SetField(_pL, "hasBefore", !before.Empty());
            SetField(_pL, "hasAfter", !after.Empty());
            SetField(_pL, "changed", static_cast<lua_Integer>(cmp.m_ChangedPixels));
            SetField(_pL, "total", static_cast<lua_Integer>(cmp.m_TotalPixels));
            return 1;
        }

        // ---- test harness -------------------------------------------------------------
        // Drive the UI from a script (GITGUD_SCRIPT) without touching the OS
        // mouse or keyboard: input goes straight into the UI backend, so it
        // exercises real hit-testing and widget behaviour.

        // gitgud.simulateClick(x, y, kind) - kind: "left" (default), "right",
        // "double".
        int LSimulateClick(lua_State* _pL)
        {
            const float fx = static_cast<float>(luaL_checknumber(_pL, 1));
            const float fy = static_cast<float>(luaL_checknumber(_pL, 2));
            const std::string kind = luaL_optstring(_pL, 3, "left");
            auto* pui = Self(_pL)->UiBackend();
            if (!pui)
            {
                return 0;
            }
            const int ibutton = kind == "right" ? 3 : 1;
            const int iclicks = kind == "double" ? 2 : 1;
            pui->SetInputSurface(luaL_optstring(_pL, 4, ""));
            pui->InjectMousePosition(fx, fy);
            for (int i = 0; i < iclicks; ++i)
            {
                pui->InjectMouseButton(ibutton, true);
                pui->InjectMouseButton(ibutton, false);
            }
            pui->SetInputSurface("");
            return 0;
        }

        // gitgud.simulateScroll(x, y, delta) - turn the mouse wheel over a
        // point (positive = away from the user, i.e. scroll up).
        int LSimulateScroll(lua_State* _pL)
        {
            const float fx = static_cast<float>(luaL_checknumber(_pL, 1));
            const float fy = static_cast<float>(luaL_checknumber(_pL, 2));
            const float fdelta = static_cast<float>(luaL_checknumber(_pL, 3));
            if (auto* pui = Self(_pL)->UiBackend())
            {
                pui->SetInputSurface(luaL_optstring(_pL, 4, ""));
                pui->InjectMousePosition(fx, fy);
                pui->InjectMouseScroll(fdelta);
                pui->SetInputSurface("");
            }
            return 0;
        }

        // gitgud.simulateText(text) - type characters into the focused widget.
        int LSimulateText(lua_State* _pL)
        {
            std::size_t len = 0;
            const char* sztext = luaL_checklstring(_pL, 1, &len);
            if (auto* pui = Self(_pL)->UiBackend())
            {
                pui->SetInputSurface(luaL_optstring(_pL, 2, ""));
                for (std::size_t i = 0; i < len; ++i)
                {
                    pui->InjectChar(static_cast<unsigned char>(sztext[i]));
                }
                pui->SetInputSurface("");
            }
            return 0;
        }

        // gitgud.screenshot(path, window?) - save the next rendered frame of the
        // main window (or of pop-out `window`) as a PNG.
        int LScreenshot(lua_State* _pL)
        {
            const std::string path = luaL_checkstring(_pL, 1);
            const std::string window = luaL_optstring(_pL, 2, "");
            if (auto* pbus = Self(_pL)->EventBus())
            {
                pbus->Publish({"debug.screenshot", window.empty() ? path : window + "\n" + path});
            }
            return 0;
        }

        // gitgud.getSelectedIndices(name) -> 1-based rows, ascending
        int LGetSelectedIndices(lua_State* _pL)
        {
            const char* szname = luaL_checkstring(_pL, 1);
            lua_newtable(_pL);
            if (auto* pui = Self(_pL)->UiBackend())
            {
                int ii = 1;
                for (const int irow : pui->GetSelectedIndices(szname))
                {
                    lua_pushinteger(_pL, irow + 1);
                    lua_rawseti(_pL, -2, ii++);
                }
            }
            return 1;
        }

        // gitgud.selectListItems(name, {rows}) - 1-based; {} clears
        int LSelectListItems(lua_State* _pL)
        {
            const char* szname = luaL_checkstring(_pL, 1);
            luaL_checktype(_pL, 2, LUA_TTABLE);
            std::vector<int> rows;
            const lua_Integer n = luaL_len(_pL, 2);
            for (lua_Integer i = 1; i <= n; ++i)
            {
                lua_rawgeti(_pL, 2, i);
                if (lua_isinteger(_pL, -1))
                {
                    rows.push_back(static_cast<int>(lua_tointeger(_pL, -1)) - 1);
                }
                lua_pop(_pL, 1);
            }
            if (auto* pui = Self(_pL)->UiBackend())
            {
                pui->SelectListItems(szname, rows);
            }
            return 0;
        }

        // gitgud.setDraggable(name, bool, direction?) - raise dragStarted /
        // dragging / dragEnded ("x,y") while the widget is dragged with the
        // left button. direction "horizontal" | "vertical" | "both" shows the
        // matching resize cursor over it (as gitgud.setCursor does).
        int LSetDraggable(lua_State* _pL)
        {
            const char* szname = luaL_checkstring(_pL, 1);
            const bool bon = lua_isnoneornil(_pL, 2) || lua_toboolean(_pL, 2) != 0;
            const std::string direction = luaL_optstring(_pL, 3, "");
            if (auto* pui = Self(_pL)->UiBackend())
            {
                pui->SetDraggable(szname, bon);
                if (!direction.empty() || !bon)
                {
                    const char* szshape = !bon                        ? ""
                                          : direction == "horizontal" ? "sizewe"
                                          : direction == "vertical"   ? "sizens"
                                          : direction == "both"       ? "sizeall"
                                                                      : "";
                    pui->SetCursorShape(szname, szshape);
                }
            }
            return 0;
        }

        // gitgud.setCursor(name, shape) - the system cursor over a widget and
        // its children: "sizewe", "sizens", "sizeall", "hand", or "" (default)
        int LSetCursor(lua_State* _pL)
        {
            const char* szname = luaL_checkstring(_pL, 1);
            const char* szshape = luaL_optstring(_pL, 2, "");
            if (auto* pui = Self(_pL)->UiBackend())
            {
                pui->SetCursorShape(szname, szshape);
            }
            return 0;
        }

        // ---- events -------------------------------------------------------------------

        int LOn(lua_State* _pL)
        {
            const char* szevent = luaL_checkstring(_pL, 1);
            luaL_checktype(_pL, 2, LUA_TFUNCTION);
            lua_pushvalue(_pL, 2);
            const int iref = luaL_ref(_pL, LUA_REGISTRYINDEX);
            Self(_pL)->RegisterHandler(szevent, iref);
            return 0;
        }

        int LEmit(lua_State* _pL)
        {
            const char* szevent = luaL_checkstring(_pL, 1);
            const char* szdetail = luaL_optstring(_pL, 2, "");
            if (auto* pbus = Self(_pL)->EventBus())
            {
                pbus->Publish({szevent, szdetail});
            }
            return 0;
        }

        // ---- timers ------------------------------------------------------------------

        // gitgud.after(ms, fn) -> id ; runs fn once
        int LAfter(lua_State* _pL)
        {
            const lua_Integer ms = luaL_checkinteger(_pL, 1);
            luaL_checktype(_pL, 2, LUA_TFUNCTION);
            lua_pushvalue(_pL, 2);
            const int iref = luaL_ref(_pL, LUA_REGISTRYINDEX);
            lua_pushinteger(_pL, Self(_pL)->AddTimer(static_cast<int>(ms), false, iref));
            return 1;
        }

        // gitgud.every(ms, fn) -> id ; runs fn repeatedly
        int LEvery(lua_State* _pL)
        {
            const lua_Integer ms = luaL_checkinteger(_pL, 1);
            luaL_checktype(_pL, 2, LUA_TFUNCTION);
            lua_pushvalue(_pL, 2);
            const int iref = luaL_ref(_pL, LUA_REGISTRYINDEX);
            lua_pushinteger(_pL, Self(_pL)->AddTimer(static_cast<int>(ms), true, iref));
            return 1;
        }

        int LCancelTimer(lua_State* _pL)
        {
            Self(_pL)->CancelTimer(static_cast<int>(luaL_checkinteger(_pL, 1)));
            return 0;
        }

        // gitgud.now() -> milliseconds on a monotonic clock
        int LNow(lua_State* _pL)
        {
            lua_pushinteger(_pL, static_cast<lua_Integer>(LuaEngine::NowMs()));
            return 1;
        }

        // ---- platform: shell, docs, config -----------------------------------------

        fs::path ExeDir()
        {
#if defined(_WIN32)
            wchar_t wszbuf[MAX_PATH] = {};
            if (GetModuleFileNameW(nullptr, wszbuf, MAX_PATH) > 0)
            {
                return fs::path(wszbuf).parent_path();
            }
#endif
            return fs::current_path();
        }

        // Per-user settings directory (recent repos, UI prefs, ...). Scripts read and
        // write it through configRead/configWrite only — never raw paths.
        fs::path ConfigDir()
        {
            return fs::u8path(gitgud::platform::ConfigDirectory());
        }

        // gitgud.docs() -> array of {name, path} for the shipped docs/ folder.
        int LDocs(lua_State* _pL)
        {
            lua_newtable(_pL);
            std::vector<fs::path> files;
            std::error_code ec;
            for (fs::directory_iterator it(ExeDir() / "docs", ec), end; !ec && it != end;
                it.increment(ec))
            {
                if (it->is_regular_file(ec))
                {
                    files.push_back(it->path());
                }
            }
            std::sort(files.begin(), files.end());
            int ii = 1;
            for (const auto& p : files)
            {
                lua_newtable(_pL);
                SetField(_pL, "name", p.filename().u8string());
                SetField(_pL, "path", p.u8string());
                lua_rawseti(_pL, -2, ii++);
            }
            return 1;
        }

        template <bool (*Fn)(const std::string&, std::string&)> int ShellCall(lua_State* _pL)
        {
            const std::string target = luaL_checkstring(_pL, 1);
            std::string error;
            if (!Fn(target, error))
            {
                return FailWith(_pL, error);
            }
            lua_pushboolean(_pL, 1);
            return 1;
        }

        // gitgud.spawn(commandLine, cwd?) — start a program detached.
        int LSpawn(lua_State* _pL)
        {
            const std::string command = luaL_checkstring(_pL, 1);
            const std::string cwd = luaL_optstring(_pL, 2, "");
            std::string error;
            if (!gitgud::platform::Spawn(command, cwd, error))
            {
                return FailWith(_pL, error);
            }
            lua_pushboolean(_pL, 1);
            return 1;
        }

        int LPickFolder(lua_State* _pL)
        {
            const std::string title = luaL_optstring(_pL, 1, "Choose a folder");
            const std::string path = gitgud::platform::PickFolder(title);
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

        int LSetClipboard(lua_State* _pL)
        {
            lua_pushboolean(_pL, gitgud::platform::SetClipboardText(luaL_checkstring(_pL, 1)));
            return 1;
        }

        int LPathExists(lua_State* _pL)
        {
            std::error_code ec;
            lua_pushboolean(_pL, fs::exists(fs::u8path(luaL_checkstring(_pL, 1)), ec));
            return 1;
        }

        // Resolve a path inside the open repository's working tree; refuses
        // absolute paths and anything that climbs out with "..".
        bool RepoFilePath(lua_State* _pL, const char* _szRelative, fs::path& _Out)
        {
            auto* prepo = Self(_pL)->Repository();
            if (!prepo)
            {
                return false;
            }
            const fs::path rel = fs::u8path(_szRelative);
            if (rel.is_absolute() || rel.has_root_name())
            {
                return false;
            }
            for (const auto& part : rel)
            {
                if (part == "..")
                {
                    return false;
                }
            }
            _Out = fs::u8path(prepo->WorkDir()) / rel;
            return true;
        }

        // gitgud.readRepoFile(relativePath) -> content or nil
        int LReadRepoFile(lua_State* _pL)
        {
            fs::path file;
            if (!RepoFilePath(_pL, luaL_checkstring(_pL, 1), file))
            {
                return FailWith(_pL, "invalid repository path");
            }
            std::ifstream in(file, std::ios::binary);
            if (!in)
            {
                lua_pushnil(_pL);
                return 1;
            }
            std::ostringstream ss;
            ss << in.rdbuf();
            const std::string content = ss.str();
            lua_pushlstring(_pL, content.data(), content.size());
            return 1;
        }

        // gitgud.writeRepoFile(relativePath, content) -> true or (nil, msg)
        int LWriteRepoFile(lua_State* _pL)
        {
            fs::path file;
            if (!RepoFilePath(_pL, luaL_checkstring(_pL, 1), file))
            {
                return FailWith(_pL, "invalid repository path");
            }
            std::size_t len = 0;
            const char* szcontent = luaL_checklstring(_pL, 2, &len);
            std::error_code ec;
            fs::create_directories(file.parent_path(), ec);
            std::ofstream out(file, std::ios::binary | std::ios::trunc);
            if (!out)
            {
                return FailWith(_pL, "could not write " + file.u8string());
            }
            out.write(szcontent, static_cast<std::streamsize>(len));
            if (auto* pbus = Self(_pL)->EventBus())
            {
                pbus->Publish({"status.changed", ""});
            }
            lua_pushboolean(_pL, 1);
            return 1;
        }

        // gitgud.trashRepoFile(relativePath) -> true or (nil, msg): move a file
        // inside the open repository to the Recycle Bin (Mark for Delete,
        // the old side of a rename)
        int LTrashRepoFile(lua_State* _pL)
        {
            fs::path file;
            if (!RepoFilePath(_pL, luaL_checkstring(_pL, 1), file))
            {
                return FailWith(_pL, "invalid repository path");
            }
            std::error_code ec;
            if (!fs::exists(file, ec))
            {
                return FailWith(_pL, "no such file: " + file.u8string());
            }
            if (!gitgud::platform::MoveToTrash(file.u8string()))
            {
                return FailWith(_pL, "could not move " + file.u8string() + " to the Recycle Bin");
            }
            if (auto* pbus = Self(_pL)->EventBus())
            {
                pbus->Publish({"status.changed", ""});
            }
            lua_pushboolean(_pL, 1);
            return 1;
        }

        // Config names are bare identifiers ("recent-repos"), never paths.
        bool ValidConfigName(const char* _szName)
        {
            if (!_szName || !*_szName)
            {
                return false;
            }
            for (const char* szc = _szName; *szc; ++szc)
            {
                if (!(std::isalnum(static_cast<unsigned char>(*szc)) || *szc == '-' ||
                        *szc == '_' || *szc == '.'))
                {
                    return false;
                }
            }
            return std::string(_szName).find("..") == std::string::npos;
        }

        int LConfigRead(lua_State* _pL)
        {
            const char* szname = luaL_checkstring(_pL, 1);
            luaL_argcheck(_pL, ValidConfigName(szname), 1, "invalid config name");
            std::ifstream in(ConfigDir() / szname, std::ios::binary);
            if (!in)
            {
                lua_pushnil(_pL);
                return 1;
            }
            std::ostringstream ss;
            ss << in.rdbuf();
            const std::string content = ss.str();
            lua_pushlstring(_pL, content.data(), content.size());
            return 1;
        }

        int LConfigWrite(lua_State* _pL)
        {
            const char* szname = luaL_checkstring(_pL, 1);
            luaL_argcheck(_pL, ValidConfigName(szname), 1, "invalid config name");
            std::size_t len = 0;
            const char* szcontent = luaL_checklstring(_pL, 2, &len);
            std::error_code ec;
            fs::create_directories(ConfigDir(), ec);
            std::ofstream out(ConfigDir() / szname, std::ios::binary | std::ios::trunc);
            if (!out)
            {
                return FailWith(_pL, "could not write config '" + std::string(szname) + "'");
            }
            out.write(szcontent, static_cast<std::streamsize>(len));
            lua_pushboolean(_pL, 1);
            return 1;
        }

    } // namespace

    void AddUiBindings(std::vector<luaL_Reg>& _Out)
    {
        using gitgud::ui::IUiBackend;
        const luaL_Reg kFunctions[] = {
            // widgets
            {"setText", LSetText},
            {"getText", LGetText},
            {"setList", LSetList},
            {"setListItem", LSetListItem},
            {"selectListItem", LSelectListItem},
            {"getScroll", LGetScroll},
            {"setScroll", LSetScroll},
            {"setEnabled", BoolSetter<&IUiBackend::SetEnabled>},
            {"setVisible", BoolSetter<&IUiBackend::SetVisible>},
            {"setChecked", BoolSetter<&IUiBackend::SetChecked>},
            {"setProperty", LSetProperty},
            {"getProperty", LGetProperty},
            {"getRect", LGetRect},
            {"focus", LFocus},
            {"textInputFocused", LTextInputFocused},
            {"bringToFront", LBringToFront},
            {"createWindow", LCreateWindow},
            {"destroyWindow", LDestroyWindow},
            {"loadLayout", LLoadLayout},
            {"suspendLayout", LSuspendLayout},
            {"linkScroll", LLinkScroll},
            {"getSelectedIndex", LGetSelectedIndex},
            {"getSelectedIndices", LGetSelectedIndices},
            {"selectListItems", LSelectListItems},
            {"setDraggable", LSetDraggable},
            {"setCursor", LSetCursor},
            // images
            {"isImage", LIsImage},
            {"imageDiff", LImageDiff},
            // events + timers
            {"on", LOn},
            {"emit", LEmit},
            {"after", LAfter},
            {"every", LEvery},
            {"cancelTimer", LCancelTimer},
            {"now", LNow},
            // test harness
            {"simulateClick", LSimulateClick},
            {"simulateText", LSimulateText},
            {"simulateScroll", LSimulateScroll},
            {"screenshot", LScreenshot},
            // platform
            {"docs", LDocs},
            {"openExternal", ShellCall<&gitgud::platform::OpenExternal>},
            {"showInFolder", ShellCall<&gitgud::platform::ShowInFolder>},
            {"spawn", LSpawn},
            {"pickFolder", LPickFolder},
            {"setClipboard", LSetClipboard},
            {"pathExists", LPathExists},
            {"readRepoFile", LReadRepoFile},
            {"writeRepoFile", LWriteRepoFile},
            {"trashRepoFile", LTrashRepoFile},
            {"configRead", LConfigRead},
            {"configWrite", LConfigWrite},
        };
        _Out.insert(_Out.end(), std::begin(kFunctions), std::end(kFunctions));
    }

} // namespace gitgud::lua::bindings
