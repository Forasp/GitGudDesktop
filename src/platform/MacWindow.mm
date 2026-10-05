#include "platform/MacWindow.h"

#import <AppKit/AppKit.h>

#include <SDL.h>
#include <SDL_syswm.h>

namespace gitgud::platform
{

    void AllowMinimize(SDL_Window* _pWindow)
    {
        SDL_SysWMinfo info;
        SDL_VERSION(&info.version);
        if (!SDL_GetWindowWMInfo(_pWindow, &info) || info.subsystem != SDL_SYSWM_COCOA)
        {
            return;
        }
        NSWindow* pwindow = info.info.cocoa.window;
        [pwindow setStyleMask:[pwindow styleMask] | NSWindowStyleMaskMiniaturizable];
    }

    void ReleaseCloseShortcut()
    {
        for (NSMenuItem* ptop in [[NSApp mainMenu] itemArray])
        {
            for (NSMenuItem* pitem in [[ptop submenu] itemArray])
            {
                if ([pitem action] == @selector(performClose:))
                {
                    [pitem setKeyEquivalent:@""];
                }
            }
        }
    }

} // namespace gitgud::platform
