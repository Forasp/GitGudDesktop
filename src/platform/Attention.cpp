#include "platform/Attention.h"

#include <SDL.h>
#include <SDL_syswm.h>

#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <shellapi.h>
#endif

namespace gitgud::platform
{

#if defined(_WIN32)

    namespace
    {
        // The notification area icon the notifications come from: added on
        // the first one, removed by ClearAttention.
        NOTIFYICONDATAW g_Icon{};
        bool g_bIconShown = false;
        constexpr UINT kIconId = 1;

        std::wstring Widen(const std::string& _Utf8)
        {
            if (_Utf8.empty())
            {
                return {};
            }
            const int iwide = MultiByteToWideChar(
                CP_UTF8, 0, _Utf8.data(), static_cast<int>(_Utf8.size()), nullptr, 0);
            std::wstring wide(static_cast<size_t>(iwide), L'\0');
            MultiByteToWideChar(
                CP_UTF8, 0, _Utf8.data(), static_cast<int>(_Utf8.size()), wide.data(), iwide);
            return wide;
        }

        // Copy into a fixed buffer, cut to fit.
        template <size_t N>
        void CopyInto(wchar_t (&_Buffer)[N], const std::wstring& _Text)
        {
            const size_t ncount = _Text.size() < N - 1 ? _Text.size() : N - 1;
            _Text.copy(_Buffer, ncount);
            _Buffer[ncount] = L'\0';
        }

        HWND WindowHandle(SDL_Window* _pWindow)
        {
            SDL_SysWMinfo info;
            SDL_VERSION(&info.version);
            if (!_pWindow || !SDL_GetWindowWMInfo(_pWindow, &info) || info.subsystem != SDL_SYSWM_WINDOWS)
            {
                return nullptr;
            }
            return info.info.win.window;
        }
    } // namespace

    bool RequestAttention(SDL_Window* _pWindow, const std::string& _Title, const std::string& _Body)
    {
        if (!_pWindow || (SDL_GetWindowFlags(_pWindow) & SDL_WINDOW_INPUT_FOCUS))
        {
            return false;
        }
        HWND hwnd = WindowHandle(_pWindow);
        if (!hwnd)
        {
            return false;
        }

        FLASHWINFO flash{};
        flash.cbSize = sizeof(flash);
        flash.hwnd = hwnd;
        flash.dwFlags = FLASHW_TRAY | FLASHW_TIMERNOFG;
        FlashWindowEx(&flash);

        if (!g_bIconShown)
        {
            g_Icon = {};
            g_Icon.cbSize = sizeof(g_Icon);
            g_Icon.hWnd = hwnd;
            g_Icon.uID = kIconId;
            g_Icon.uFlags = NIF_ICON | NIF_TIP;
            HICON hicon = reinterpret_cast<HICON>(SendMessageW(hwnd, WM_GETICON, ICON_SMALL, 0));
            if (!hicon)
            {
                hicon = reinterpret_cast<HICON>(GetClassLongPtrW(hwnd, GCLP_HICONSM));
            }
            g_Icon.hIcon = hicon ? hicon : LoadIconW(nullptr, MAKEINTRESOURCEW(32512)); // IDI_APPLICATION
            wchar_t sztitle[128] = {};
            GetWindowTextW(hwnd, sztitle, 128);
            CopyInto(g_Icon.szTip, sztitle);
            if (!Shell_NotifyIconW(NIM_ADD, &g_Icon))
            {
                return false;
            }
            g_bIconShown = true;
        }

        g_Icon.uFlags = NIF_INFO;
        g_Icon.dwInfoFlags = NIIF_INFO;
        CopyInto(g_Icon.szInfoTitle, Widen(_Title));
        CopyInto(g_Icon.szInfo, Widen(_Body.empty() ? std::string(" ") : _Body));
        return Shell_NotifyIconW(NIM_MODIFY, &g_Icon) != FALSE;
    }

    void ClearAttention()
    {
        if (g_bIconShown)
        {
            g_Icon.uFlags = 0;
            Shell_NotifyIconW(NIM_DELETE, &g_Icon);
            g_bIconShown = false;
        }
    }

    void SendToBack(SDL_Window* _pWindow)
    {
        if (HWND hwnd = WindowHandle(_pWindow))
        {
            SetWindowPos(hwnd, HWND_BOTTOM, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        }
    }

#else

    bool RequestAttention(SDL_Window*, const std::string&, const std::string&)
    {
        return false;
    }

    void ClearAttention() {}

    void SendToBack(SDL_Window*) {}

#endif

} // namespace gitgud::platform
