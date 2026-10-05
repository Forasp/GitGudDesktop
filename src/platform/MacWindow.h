#pragma once

// -----------------------------------------------------------------------------
// MacWindow: macOS window and menu details SDL leaves as they are
// (MacWindow.mm).
// -----------------------------------------------------------------------------

#if defined(__APPLE__)

struct SDL_Window;

namespace gitgud::platform
{

    // macOS only minimises a window whose style allows it, and SDL gives a
    // borderless window none: allow it, so Command+M and the title bar's
    // minimise button work. Call again after the window's border changes.
    void AllowMinimize(SDL_Window* _pWindow);

    // SDL's Window menu gives Command+W to Close, which a borderless window
    // can't do and which the app binds itself (close tab): give it back to
    // the app. Call once after SDL_Init.
    void ReleaseCloseShortcut();

} // namespace gitgud::platform

#endif
