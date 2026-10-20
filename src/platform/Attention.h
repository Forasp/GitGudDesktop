#pragma once

// -----------------------------------------------------------------------------
// Attention: asking for the user while the app is in the background, when an
// agent session finishes or needs a permission (Attention.cpp).
// -----------------------------------------------------------------------------

#include <string>

struct SDL_Window;

namespace gitgud::platform
{

    // Flash the window's taskbar button until it comes forward, and show a
    // desktop notification with `_Title` and `_Body`. Does nothing while the
    // window has the keyboard focus. Windows only so far: false elsewhere.
    bool RequestAttention(SDL_Window* _pWindow, const std::string& _Title, const std::string& _Body);

    // Take the notification's icon away again (the window came forward, or
    // the app is closing).
    void ClearAttention();

    // Put the window behind every other window without activating it (UI
    // test runs in the background, test windows took the
    // screen). Windows only so far: nothing elsewhere.
    void SendToBack(SDL_Window* _pWindow);

} // namespace gitgud::platform
