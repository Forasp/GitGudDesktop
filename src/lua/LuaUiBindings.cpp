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
#include <utility>
#include <vector>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

#include "app/EventBus.h"
#include "git/Repository.h"
#include "imaging/ImageDiff.h"
#include "platform/Shell.h"
#include "platform/SpellCheck.h"
#include "ui/IUiBackend.h"
#include "ui/TextSpans.h"

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

        // gitgud.uiStats() -> windows, windows drawn: how big the UI is (every
        // drawn window's text goes to the renderer at each redraw).
        int LUiStats(lua_State* _pL)
        {
            int itotal = 0;
            int idrawn = 0;
            if (auto* pui = Self(_pL)->UiBackend())
            {
                pui->CountWindows(itotal, idrawn);
            }
            lua_pushinteger(_pL, itotal);
            lua_pushinteger(_pL, idrawn);
            return 2;
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

        // gitgud.getScrollMax(name, "horizontal"?): the furthest getScroll goes.
        int LGetScrollMax(lua_State* _pL)
        {
            const char* szid = luaL_checkstring(_pL, 1);
            float fmax = 0.0f;
            if (auto* pui = Self(_pL)->UiBackend())
            {
                fmax = pui->GetScrollMax(
                    szid, std::string(luaL_optstring(_pL, 2, "")) == "horizontal");
            }
            lua_pushnumber(_pL, fmax);
            return 1;
        }

        // gitgud.watchScroll(name): "<name>.scrolled" (the offset) from now on.
        int LWatchScroll(lua_State* _pL)
        {
            const char* szid = luaL_checkstring(_pL, 1);
            if (auto* pui = Self(_pL)->UiBackend())
            {
                pui->WatchScroll(szid);
            }
            return 0;
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

        // Rectangles as { {x, y, width, height}, ... }.
        void PushRects(lua_State* _pL, const std::vector<gitgud::ui::PixelRect>& _Rects)
        {
            lua_createtable(_pL, static_cast<int>(_Rects.size()), 0);
            for (size_t ni = 0; ni < _Rects.size(); ++ni)
            {
                const auto& rect = _Rects[ni];
                lua_createtable(_pL, 4, 0);
                const float values[] = {rect.m_fX, rect.m_fY, rect.m_fWidth, rect.m_fHeight};
                for (int ii = 0; ii < 4; ++ii)
                {
                    lua_pushnumber(_pL, values[ii]);
                    lua_rawseti(_pL, -2, ii + 1);
                }
                lua_rawseti(_pL, -2, static_cast<lua_Integer>(ni + 1));
            }
        }

        // gitgud.textRects(name, first, last) -> { {x, y, width, height}, ... }:
        // where bytes first..last of a static text's text are drawn, one
        // rectangle per line, relative to the widget
        int LTextRects(lua_State* _pL)
        {
            const char* szid = luaL_checkstring(_pL, 1);
            const lua_Integer ifirst = luaL_checkinteger(_pL, 2);
            const lua_Integer ilast = luaL_checkinteger(_pL, 3);
            std::vector<gitgud::ui::PixelRect> rects;
            auto* pui = Self(_pL)->UiBackend();
            if (pui && ifirst > 0 && ilast >= ifirst)
            {
                rects =
                    pui->TextRects(szid, static_cast<size_t>(ifirst), static_cast<size_t>(ilast));
            }
            PushRects(_pL, rects);
            return 1;
        }

        // gitgud.shownRects(name, first, last) -> { {x, y, width, height}, ... }:
        // textRects for the characters a static text shows at indices
        // first..last (0-based, inclusive; the code points of shownText)
        int LShownRects(lua_State* _pL)
        {
            const char* szid = luaL_checkstring(_pL, 1);
            const lua_Integer ifirst = luaL_checkinteger(_pL, 2);
            const lua_Integer ilast = luaL_checkinteger(_pL, 3);
            std::vector<gitgud::ui::PixelRect> rects;
            auto* pui = Self(_pL)->UiBackend();
            if (pui && ifirst >= 0 && ilast >= ifirst)
            {
                rects =
                    pui->ShownRects(szid, static_cast<size_t>(ifirst), static_cast<size_t>(ilast));
            }
            PushRects(_pL, rects);
            return 1;
        }

        // gitgud.shownText(name) -> the text a widget shows: its markup with
        // the tags left out, [br] as a line break, escapes read
        int LShownText(lua_State* _pL)
        {
            const char* szid = luaL_checkstring(_pL, 1);
            auto* pui = Self(_pL)->UiBackend();
            const std::string shown =
                pui ? gitgud::ui::ShownText(pui->GetText(szid)) : std::string();
            lua_pushlstring(_pL, shown.data(), shown.size());
            return 1;
        }

        // gitgud.textIndexAt(name, x, y) -> where a caret at window pixel
        // (x, y) goes in a static text (0: before its first character), or
        // nil when it isn't one
        int LTextIndexAt(lua_State* _pL)
        {
            const char* szid = luaL_checkstring(_pL, 1);
            const float fx = static_cast<float>(luaL_checknumber(_pL, 2));
            const float fy = static_cast<float>(luaL_checknumber(_pL, 3));
            auto* pui = Self(_pL)->UiBackend();
            const long lindex = pui ? pui->TextIndexAt(szid, fx, fy) : -1;
            if (lindex < 0)
            {
                lua_pushnil(_pL);
            }
            else
            {
                lua_pushinteger(_pL, static_cast<lua_Integer>(lindex));
            }
            return 1;
        }

        // gitgud.watchPointer(name): "<name>.pointerDown" / "pointerMoved" /
        // "pointerUp" for the mouse over it from now on (IUiBackend::WatchPointer)
        int LWatchPointer(lua_State* _pL)
        {
            const char* szid = luaL_checkstring(_pL, 1);
            if (auto* pui = Self(_pL)->UiBackend())
            {
                pui->WatchPointer(szid);
            }
            return 0;
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
        // gitgud.themeColour(name) -> "AARRGGBB" for a named token of the
        // running theme ("accent"), or nil when the theme doesn't define it.
        int LThemeColour(lua_State* _pL)
        {
            const char* szname = luaL_checkstring(_pL, 1);
            auto* pui = Self(_pL)->UiBackend();
            const std::string colour = pui ? pui->ThemeColour(szname) : std::string();
            if (colour.empty())
            {
                lua_pushnil(_pL);
            }
            else
            {
                lua_pushstring(_pL, colour.c_str());
            }
            return 1;
        }

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

        // gitgud.simulateMove(x, y, window?) - the mouse moves there, no
        // button (hover).
        int LSimulateMove(lua_State* _pL)
        {
            const float fx = static_cast<float>(luaL_checknumber(_pL, 1));
            const float fy = static_cast<float>(luaL_checknumber(_pL, 2));
            auto* pui = Self(_pL)->UiBackend();
            if (!pui)
            {
                return 0;
            }
            pui->SetInputSurface(luaL_optstring(_pL, 3, ""));
            pui->InjectMousePosition(fx, fy);
            pui->SetInputSurface("");
            return 0;
        }

        // gitgud.simulateDrag(x1, y1, x2, y2, window?) - press the left button
        // at (x1, y1), move to (x2, y2) in steps, and release (splitters,
        // dividers, list reordering).
        int LSimulateDrag(lua_State* _pL)
        {
            const float fx1 = static_cast<float>(luaL_checknumber(_pL, 1));
            const float fy1 = static_cast<float>(luaL_checknumber(_pL, 2));
            const float fx2 = static_cast<float>(luaL_checknumber(_pL, 3));
            const float fy2 = static_cast<float>(luaL_checknumber(_pL, 4));
            auto* pui = Self(_pL)->UiBackend();
            if (!pui)
            {
                return 0;
            }
            constexpr int ikSteps = 8;
            pui->SetInputSurface(luaL_optstring(_pL, 5, ""));
            pui->InjectMousePosition(fx1, fy1);
            pui->InjectMouseButton(1, true);
            for (int i = 1; i <= ikSteps; ++i)
            {
                const float ft = static_cast<float>(i) / ikSteps;
                pui->InjectMousePosition(fx1 + (fx2 - fx1) * ft, fy1 + (fy2 - fy1) * ft);
            }
            pui->InjectMouseButton(1, false);
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

        // gitgud.simulateKey(combo, window?) - press and release a key in the
        // focused widget, holding the combo's modifiers: "enter",
        // "shift+enter", "ctrl+a". Only the widget sees it; bound shortcuts
        // take gitgud.emit("key", combo).
        int LSimulateKey(lua_State* _pL)
        {
            // SDL scancodes (USB usage ids), so this file needs no SDL.
            static const std::pair<const char*, int> kKeys[] = {
                {"enter", 40},
                {"escape", 41},
                {"backspace", 42},
                {"tab", 43},
                {"right", 79},
                {"left", 80},
                {"down", 81},
                {"up", 82},
                {"ctrl", 224},
                {"shift", 225},
                {"alt", 226},
            };
            auto scancode = [](const std::string& _Name)
            {
                if (_Name.size() == 1 && _Name[0] >= 'a' && _Name[0] <= 'z')
                {
                    return 4 + (_Name[0] - 'a');
                }
                for (const auto& [szname, icode] : kKeys)
                {
                    if (_Name == szname)
                    {
                        return icode;
                    }
                }
                return -1;
            };

            std::vector<int> keys;
            std::stringstream combo(luaL_checkstring(_pL, 1));
            for (std::string part; std::getline(combo, part, '+');)
            {
                const int icode = scancode(part);
                if (icode < 0)
                {
                    return luaL_error(_pL, "simulateKey: unknown key '%s'", part.c_str());
                }
                keys.push_back(icode);
            }
            auto* pui = Self(_pL)->UiBackend();
            if (!pui || keys.empty())
            {
                return 0;
            }
            pui->SetInputSurface(luaL_optstring(_pL, 2, ""));
            for (const int icode : keys)
            {
                pui->InjectKey(icode, true);
            }
            for (auto it = keys.rbegin(); it != keys.rend(); ++it)
            {
                pui->InjectKey(*it, false);
            }
            pui->SetInputSurface("");
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
        // its children: "sizewe", "sizens", "sizeall", "hand", "ibeam",
        // "arrow", or "" (default)
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

        // gitgud.off(event): drop every handler of the event (a window that's
        // gone: its handlers would stay for good).
        int LOff(lua_State* _pL)
        {
            Self(_pL)->UnregisterHandlers(luaL_checkstring(_pL, 1));
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

        // gitgud.skipTime(ms) - test harness only (GITGUD_SCRIPT): move
        // gitgud.now() and the timers' clock ahead, as if ms had passed.
        int LSkipTime(lua_State* _pL)
        {
            const lua_Integer ms = luaL_checkinteger(_pL, 1);
            if (!std::getenv("GITGUD_SCRIPT"))
            {
                return luaL_error(_pL, "gitgud.skipTime is for the test harness (GITGUD_SCRIPT)");
            }
            LuaEngine::SkipClock(static_cast<int>(ms));
            return 0;
        }

        // gitgud.nextTimer() -> ms until the next timer is due (0 if overdue),
        // or -1 when none is pending (the running one-shot doesn't count).
        int LNextTimer(lua_State* _pL)
        {
            lua_pushinteger(_pL, Self(_pL)->MillisecondsUntilNextTimer());
            return 1;
        }

        // ---- platform: shell, docs, config -----------------------------------------

        fs::path ExeDir()
        {
            return fs::u8path(gitgud::platform::ExecutableDirectory());
        }

        // gitgud.appDir() -> the folder the app runs from (resources/, docs/, and
        // on Linux the bundled gh live there).
        int LAppDir(lua_State* _pL)
        {
            const std::string dir = ExeDir().u8string();
            lua_pushlstring(_pL, dir.data(), dir.size());
            return 1;
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

        // gitgud.pickFile(title?, filterName?, pattern?) -> path | nil
        int LPickFile(lua_State* _pL)
        {
            const std::string title = luaL_optstring(_pL, 1, "Choose a file");
            const std::string name = luaL_optstring(_pL, 2, "");
            const std::string pattern = luaL_optstring(_pL, 3, "");
            const std::string path = gitgud::platform::PickFile(title, name, pattern);
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

        // gitgud.isDictionaryWord(text) -> true / false, or nil when there's
        // no answer (platform/SpellCheck.h).
        int LIsDictionaryWord(lua_State* _pL)
        {
            const std::optional<bool> oanswer =
                gitgud::platform::IsDictionaryWord(luaL_checkstring(_pL, 1));
            if (oanswer)
            {
                lua_pushboolean(_pL, *oanswer);
            }
            else
            {
                lua_pushnil(_pL);
            }
            return 1;
        }

        // gitgud.pathExists(path) -> true, "file" | "folder"; or false
        int LPathExists(lua_State* _pL)
        {
            std::error_code ec;
            const fs::file_status status = fs::status(fs::u8path(luaL_checkstring(_pL, 1)), ec);
            if (ec || !fs::exists(status))
            {
                lua_pushboolean(_pL, 0);
                return 1;
            }
            lua_pushboolean(_pL, 1);
            lua_pushstring(_pL, fs::is_directory(status) ? "folder" : "file");
            return 2;
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

        // Config names are bare identifiers ("recent-repos"), or such names
        // joined by '/' for a file in a folder of the config folder
        // ("voice-recordings/2026-10-15-170000.wav"); never other paths.
        bool ValidConfigName(const char* _szName)
        {
            if (!_szName || std::string(_szName).find("..") != std::string::npos)
            {
                return false;
            }
            // Each part: not empty, not ".", and only these characters.
            std::string part;
            for (const char* szc = _szName;; ++szc)
            {
                if (*szc == '/' || !*szc)
                {
                    if (part.empty() || part == ".")
                    {
                        return false;
                    }
                    if (!*szc)
                    {
                        return true;
                    }
                    part.clear();
                }
                else if (std::isalnum(static_cast<unsigned char>(*szc)) || *szc == '-' || *szc == '_' ||
                         *szc == '.')
                {
                    part += *szc;
                }
                else
                {
                    return false;
                }
            }
        }

        int LConfigRead(lua_State* _pL)
        {
            const char* szname = luaL_checkstring(_pL, 1);
            luaL_argcheck(_pL, ValidConfigName(szname), 1, "invalid config name");
            std::ifstream in(ConfigDir() / fs::u8path(szname), std::ios::binary);
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
            // Atomic: a crash leaves the old file or the new one, never half.
            const fs::path file = ConfigDir() / fs::u8path(szname);
            std::string error;
            if (!gitgud::platform::WriteFileAtomically(file.u8string(), std::string(szcontent, len), error))
            {
                return FailWith(_pL, "could not write config '" + std::string(szname) + "': " + error);
            }
            lua_pushboolean(_pL, 1);
            return 1;
        }

        // gitgud.configPath(name?) -> the full path of a config file or
        // folder (the config folder itself without a name); it may not exist.
        int LConfigPath(lua_State* _pL)
        {
            fs::path path = ConfigDir();
            if (!lua_isnoneornil(_pL, 1))
            {
                const char* szname = luaL_checkstring(_pL, 1);
                luaL_argcheck(_pL, ValidConfigName(szname), 1, "invalid config name");
                path /= fs::u8path(szname);
            }
            const std::string u8 = path.make_preferred().u8string();
            lua_pushlstring(_pL, u8.data(), u8.size());
            return 1;
        }

        // gitgud.configList(folder) -> { {name, size}, ... }: the files in a
        // folder of the config folder, by name ({} when it doesn't exist).
        int LConfigList(lua_State* _pL)
        {
            const char* szfolder = luaL_checkstring(_pL, 1);
            luaL_argcheck(_pL, ValidConfigName(szfolder), 1, "invalid config name");
            std::vector<std::pair<std::string, uintmax_t>> files;
            std::error_code ec;
            for (fs::directory_iterator it(ConfigDir() / fs::u8path(szfolder), ec), end; !ec && it != end;
                 it.increment(ec))
            {
                std::error_code ecfile;
                if (it->is_regular_file(ecfile))
                {
                    const uintmax_t usize = it->file_size(ecfile);
                    files.emplace_back(it->path().filename().u8string(), ecfile ? 0 : usize);
                }
            }
            std::sort(files.begin(), files.end());
            lua_createtable(_pL, static_cast<int>(files.size()), 0);
            for (std::size_t i = 0; i < files.size(); ++i)
            {
                lua_createtable(_pL, 0, 2);
                lua_pushlstring(_pL, files[i].first.data(), files[i].first.size());
                lua_setfield(_pL, -2, "name");
                lua_pushinteger(_pL, static_cast<lua_Integer>(files[i].second));
                lua_setfield(_pL, -2, "size");
                lua_rawseti(_pL, -2, static_cast<lua_Integer>(i + 1));
            }
            return 1;
        }

        // gitgud.configRemove(name) -> true | nil, msg: delete a config file
        // (not a folder).
        int LConfigRemove(lua_State* _pL)
        {
            const char* szname = luaL_checkstring(_pL, 1);
            luaL_argcheck(_pL, ValidConfigName(szname), 1, "invalid config name");
            const fs::path file = ConfigDir() / fs::u8path(szname);
            std::error_code ec;
            if (!fs::is_regular_file(file, ec))
            {
                return FailWith(_pL, "no such config file: " + std::string(szname));
            }
            if (!fs::remove(file, ec))
            {
                return FailWith(_pL, "could not remove " + std::string(szname) + ": " + ec.message());
            }
            lua_pushboolean(_pL, 1);
            return 1;
        }

        // gitgud.makeDir(path) -> true | nil, msg: make a folder and its parents.
        int LMakeDir(lua_State* _pL)
        {
            const std::string path = luaL_checkstring(_pL, 1);
            if (path.empty())
            {
                return FailWith(_pL, "no folder given");
            }
            std::error_code ec;
            fs::create_directories(fs::u8path(path), ec);
            if (!fs::is_directory(fs::u8path(path), ec))
            {
                return FailWith(_pL, "could not make the folder " + path +
                                         (ec ? ": " + ec.message() : std::string()));
            }
            lua_pushboolean(_pL, 1);
            return 1;
        }

    } // namespace

    bool IsConfigName(const char* _szName)
    {
        return ValidConfigName(_szName);
    }

    std::string ConfigFile(const std::string& _Name)
    {
        return (ConfigDir() / fs::u8path(_Name)).u8string();
    }

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
            {"getScrollMax", LGetScrollMax},
            {"watchScroll", LWatchScroll},
            {"setEnabled", BoolSetter<&IUiBackend::SetEnabled>},
            {"setVisible", BoolSetter<&IUiBackend::SetVisible>},
            {"setChecked", BoolSetter<&IUiBackend::SetChecked>},
            {"setProperty", LSetProperty},
            {"getProperty", LGetProperty},
            {"getRect", LGetRect},
            {"textRects", LTextRects},
            {"shownRects", LShownRects},
            {"shownText", LShownText},
            {"textIndexAt", LTextIndexAt},
            {"watchPointer", LWatchPointer},
            {"focus", LFocus},
            {"textInputFocused", LTextInputFocused},
            {"bringToFront", LBringToFront},
            {"createWindow", LCreateWindow},
            {"destroyWindow", LDestroyWindow},
            {"loadLayout", LLoadLayout},
            {"themeColour", LThemeColour},
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
            {"off", LOff},
            {"emit", LEmit},
            {"after", LAfter},
            {"every", LEvery},
            {"cancelTimer", LCancelTimer},
            {"now", LNow},
            {"skipTime", LSkipTime},
            {"nextTimer", LNextTimer},
            // test harness
            {"simulateClick", LSimulateClick},
            {"simulateText", LSimulateText},
            {"simulateKey", LSimulateKey},
            {"simulateDrag", LSimulateDrag},
            {"simulateMove", LSimulateMove},
            {"simulateScroll", LSimulateScroll},
            {"screenshot", LScreenshot},
            // platform
            {"docs", LDocs},
            {"appDir", LAppDir},
            {"openExternal", ShellCall<&gitgud::platform::OpenExternal>},
            {"showInFolder", ShellCall<&gitgud::platform::ShowInFolder>},
            {"spawn", LSpawn},
            {"pickFolder", LPickFolder},
            {"pickFile", LPickFile},
            {"setClipboard", LSetClipboard},
            {"pathExists", LPathExists},
            {"isDictionaryWord", LIsDictionaryWord},
            {"readRepoFile", LReadRepoFile},
            {"writeRepoFile", LWriteRepoFile},
            {"trashRepoFile", LTrashRepoFile},
            {"uiStats", LUiStats},
            {"configRead", LConfigRead},
            {"makeDir", LMakeDir},
            {"configWrite", LConfigWrite},
            {"configPath", LConfigPath},
            {"configList", LConfigList},
            {"configRemove", LConfigRemove},
        };
        _Out.insert(_Out.end(), std::begin(kFunctions), std::end(kFunctions));
    }

} // namespace gitgud::lua::bindings
