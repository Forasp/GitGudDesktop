#pragma once

// -----------------------------------------------------------------------------
// IAppHost — what scripts may ask of the application shell (main.cpp owns
// the OS windows and the UI lifecycle, so it implements this):
//
//   * pop-out windows — extra OS windows showing their own layout (a diff,
//     a revision graph). Their widgets join the one widget namespace with
//     the window id as a prefix: layout widget "Graph" in window "revgraph"
//     is "revgraph:Graph" to Lua.
//   * user-interface packages — which UI (see app/UiPackages.h) is running,
//     and switching to another one (applied after the current event).
//   * the main window's frame.
// -----------------------------------------------------------------------------

#include <string>
#include <vector>

#include "app/UiPackages.h"

namespace gitgud::app
{

    struct WindowSpec
    {
        std::string m_Id;     // unique; letters, digits, '-' and '_'
        std::string m_Title;  // OS title bar text
        std::string m_Layout; // layout file, relative to the UI's layouts/
        int m_iWidth = 900;
        int m_iHeight = 600;
        int m_iMinWidth = 320;
        int m_iMinHeight = 200;
    };

    class IAppHost
    {
      public:
        virtual ~IAppHost() = default;

        // Pop-out windows ---------------------------------------------------------
        // Open a window (an id already open is just raised). False with a message
        // when the layout can't be loaded or the window can't be created.
        virtual bool OpenWindow(const WindowSpec& _Spec, std::string& _Error) = 0;
        // Close it; "window.closed" (detail = id) is published either way the
        // window goes away (this call or the user's close button).
        virtual void CloseWindow(const std::string& _Id) = 0;
        virtual void SetWindowTitle(const std::string& _Id, const std::string& _Title) = 0;
        virtual void FocusWindow(const std::string& _Id) = 0;
        virtual std::vector<std::string> OpenWindows() const = 0;

        // The main window's OS frame: true = native title bar and borders (the
        // P4V-style UI), false = borderless with a drawn title bar (default UI).
        virtual void SetMainWindowBordered(bool _bBordered) = 0;

        // User-interface packages -------------------------------------------------
        virtual const UiPackage& CurrentUi() const = 0;
        // The UI that was running before the current one ("" when none) — the
        // picker returns there on Cancel.
        virtual std::string PreviousUi() const = 0;
        virtual std::vector<UiPackage> AvailableUis() const = 0;
        // Switch after the current event handler returns. `_bRemember` stores the
        // choice for the next launch. False with a message for an invalid spec.
        virtual bool RequestUiSwitch(
            const std::string& _Spec, bool _bRemember, std::string& _Error) = 0;
        // True on the first launch (no stored choice yet).
        virtual bool FirstLaunch() const = 0;
    };

} // namespace gitgud::app
