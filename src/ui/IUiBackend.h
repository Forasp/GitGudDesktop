#pragma once

// -----------------------------------------------------------------------------
// IUiBackend — the seam between the application and whatever renders the GUI.
//
// The rest of Gitgud (Git engine, controllers, app state) talks to the UI ONLY
// through this interface. CEGUI hides behind CeguiBackend today; a future custom
// XML+Lua renderer implements the same interface and nothing above it changes.
//
// Keep this interface small and rendering-agnostic. It deals in layouts, named
// widgets, and events — never in CEGUI/OpenGL/SDL types.
// -----------------------------------------------------------------------------

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace gitgud::ui
{

    // A UI-raised intent. The app subscribes to these; it never reads widgets back.
    // Actions raised today (see docs/LUA_API.md for payloads):
    //   clicked, toggled, selected, accepted, changed, rightClicked, doubleClicked,
    //   dragged
    // (lists report "clicked" and "rightClicked" as "x,y,row", and "dragged"
    // as "fromRow,toRow" when the mouse is pressed on one row and released on
    // another).
    struct WidgetEvent
    {
        std::string m_WidgetId; // e.g. "commitButton"
        std::string m_Action;   // e.g. "clicked", "selected"
        std::string m_Value;    // optional payload (selected item, text, ...)
    };

    // A widget's absolute on-screen rectangle, in pixels.
    struct PixelRect
    {
        float m_fX = 0.0f;
        float m_fY = 0.0f;
        float m_fWidth = 0.0f;
        float m_fHeight = 0.0f;
    };

    // One named sub-rectangle of an image atlas (see DefineImageAtlas).
    struct ImageRegion
    {
        std::string m_Name;
        int m_iX = 0;
        int m_iY = 0;
        int m_iWidth = 0;
        int m_iHeight = 0;
    };

    using EventHandler = std::function<void(const WidgetEvent&)>;

    class IUiBackend
    {
      public:
        virtual ~IUiBackend() = default;

        // Lifecycle -------------------------------------------------------------
        // Bring up the backend against an existing GL context / window size.
        // `resourceRoot` is the absolute path to the app's resources/ directory
        // (resolved from the executable location, NOT the working directory --
        // the cwd belongs to whatever repo the user opened).
        virtual bool Initialize(
            int _iWindowWidth, int _iWindowHeight, const std::string& _ResourceRoot) = 0;
        virtual void Shutdown() = 0;

        // Load an XML layout file (path relative to resources/layouts) and make it
        // the active root. Returns false on parse/load failure.
        virtual bool LoadLayout(const std::string& _LayoutFile) = 0;

        // Load a layout file and attach its root window under `_ParentId` (how
        // modules add their own XML at runtime). Its widgets raise events like
        // any other. Returns false on failure or name clashes.
        virtual bool LoadLayoutInto(
            const std::string& _LayoutFile, const std::string& _ParentId) = 0;

        // User-interface packages (app/UiPackages.h) ------------------------------
        // Folder layout files resolve against: the running UI's layouts/. The base
        // resources/layouts stays reachable as resource group "gitgud-layouts", so
        // a package can import shared pieces:
        //   <LayoutImport filename="dialogs/dialog.xml" resourceGroup="gitgud-layouts"/>
        virtual void SetLayoutDirectory(const std::string& _Directory) = 0;
        // Re-apply the skin for a UI package ("" = the base skin only): the base
        // looknfeel, then every .xml in <package>/looknfeel on top — a package
        // restyles "Gitgud/Button" and friends by redefining those looks — and
        // every imageset in <package>/imagesets (its own icons). Call with no
        // windows alive (after UnloadAll).
        virtual void ApplySkin(const std::string& _PackageRoot) = 0;
        // Destroy the main window's widgets and every surface.
        virtual void UnloadAll() = 0;

        // Surfaces: extra OS windows (pop-outs) -------------------------------------
        // Each has its own widget tree, loaded from a layout whose widget names
        // are prefixed with "<surfaceId>:" (one namespace across all windows). All
        // surfaces share the main window's GL context: make the surface's window
        // current before RenderSurface. "" means the main window below.
        virtual bool CreateSurface(const std::string& _SurfaceId, int _iWidth, int _iHeight,
            const std::string& _LayoutFile) = 0;
        virtual void DestroySurface(const std::string& _SurfaceId) = 0;
        virtual void ResizeSurface(const std::string& _SurfaceId, int _iWidth, int _iHeight) = 0;
        virtual bool SurfaceNeedsRedraw(const std::string& _SurfaceId) const = 0;
        virtual void RenderSurface(const std::string& _SurfaceId) = 0;
        // Route the Inject* calls below (and IsTextInputFocused) to a surface.
        virtual void SetInputSurface(const std::string& _SurfaceId) = 0;
        // Draw a surface's cursor or not (the mouse entered / left its window).
        virtual void SetCursorVisible(const std::string& _SurfaceId, bool _bVisible) = 0;

        // Per-frame ------------------------------------------------------------
        // Resize / NeedsRedraw / Render act on the main window.
        virtual void Resize(int _iWindowWidth, int _iWindowHeight) = 0;
        // Advance timers/animations (caret blink, tooltips) by `_fElapsed` s, in
        // every window.
        virtual void Update(float _fElapsed) = 0;
        // True when something changed since the last Render() — lets the main
        // loop skip drawing (and sleep) while the app is idle.
        virtual bool NeedsRedraw() const = 0;
        virtual void Render() = 0;

        // Feed raw input from the windowing layer. Kept generic so backends can map
        // it however they like. (Expand as needed: mouse move/button, key, text.)
        virtual void InjectMousePosition(float _fX, float _fY) = 0;
        virtual void InjectMouseButton(int _iButton, bool _bDown) = 0;
        // Wheel scroll; positive delta scrolls up/away from the user.
        virtual void InjectMouseScroll(float _fDelta) = 0;
        virtual void InjectChar(unsigned int _uiCodepoint) = 0;
        // Non-text keys (backspace, arrows, enter, ...). Takes SDL scancodes;
        // backends translate to their own key representation.
        virtual void InjectKey(int _iSdlScancode, bool _bDown) = 0;

        // State push (app -> UI) -----------------------------------------------
        // The app sets widget content from application state. One-way: the app is
        // the source of truth; the UI only displays.
        virtual void SetText(const std::string& _WidgetId, const std::string& _Text) = 0;
        // Replace a list's rows (keeps its scroll position where possible).
        virtual void SetList(
            const std::string& _WidgetId, const std::vector<std::string>& _Items) = 0;
        virtual void SetEnabled(const std::string& _WidgetId, bool _bEnabled) = 0;
        virtual void SetVisible(const std::string& _WidgetId, bool _bVisible) = 0;
        // Toggle a checkbox-like widget without raising its change event back at
        // the app (used to reflect model state into the checkbox).
        virtual void SetChecked(const std::string& _WidgetId, bool _bChecked) = 0;
        // Generic escape hatch: set any backend property ("NormalFillColour",
        // "Font", ...). This is what lets Lua re-theme widgets at runtime.
        virtual void SetProperty(const std::string& _WidgetId, const std::string& _Property,
            const std::string& _Value) = 0;
        // Keep two list widgets' vertical scroll positions in step (used by the
        // split diff). Links are transitive: linking A-B and B-C scrolls all
        // three together (multi-column tables). Safe to call again with the same
        // pair after a reload.
        virtual void LinkScroll(const std::string& _WidgetIdA, const std::string& _WidgetIdB) = 0;

        // Replace one row of a list (0-based) without rebuilding the rest — keeps
        // scroll position and costs O(1) instead of O(rows).
        virtual void SetListItem(
            const std::string& _WidgetId, int _iIndex, const std::string& _Text) = 0;
        // Select row `_iIndex` (0-based; -1 clears) without raising "selected",
        // optionally scrolling it into view.
        virtual void SelectListItem(
            const std::string& _WidgetId, int _iIndex, bool _bEnsureVisible) = 0;
        // Multi-select lists (the "MultiSelect" property: Ctrl+click adds a row,
        // Shift+click a range): select exactly these rows (0-based), without
        // raising "selected".
        virtual void SelectListItems(
            const std::string& _WidgetId, const std::vector<int>& _Rows) = 0;
        // Opt a widget into drag events: while the left button is held after
        // pressing on it, "<id>.dragging" reports the cursor ("x,y", window
        // pixels), then "<id>.dragEnded"; "<id>.dragStarted" comes first. For
        // splitters, column dividers, panning a picture.
        virtual void SetDraggable(const std::string& _WidgetId, bool _bDraggable) = 0;
        // The system mouse cursor shown over a widget (and its children), and
        // kept while it is being dragged: "sizewe" (left-right arrows),
        // "sizens" (up-down), "sizeall" (four arrows), "hand", or "" for the
        // UI's own cursor.
        virtual void SetCursorShape(const std::string& _WidgetId, const std::string& _Shape) = 0;
        // Scroll offset (pixels) of a list or scrollable pane: vertical, or
        // horizontal with `_bHorizontal`.
        virtual float GetScroll(const std::string& _WidgetId, bool _bHorizontal = false) const = 0;
        virtual void SetScroll(
            const std::string& _WidgetId, float _fPosition, bool _bHorizontal = false) = 0;
        // Give keyboard focus to a widget (e.g. the filter box of a popup).
        virtual void Focus(const std::string& _WidgetId) = 0;
        // Raise a widget above its siblings (popups opened over each other).
        virtual void BringToFront(const std::string& _WidgetId) = 0;
        // Publish an RGBA8 image under `_ImageName` so layouts/Lua can show it via
        // an "Image" property; re-defining a name replaces the pixels in place.
        virtual bool DefineImage(const std::string& _ImageName, int _iWidth, int _iHeight,
            const std::vector<std::uint8_t>& _Rgba) = 0;
        // Upload ONE texture and publish several images cut from it (the
        // commit graph: hundreds of row pictures, one texture). Region names
        // are image names like DefineImage's; re-defining replaces them.
        virtual bool DefineImageAtlas(const std::string& _TextureName, int _iWidth, int _iHeight,
            const std::vector<std::uint8_t>& _Rgba, const std::vector<ImageRegion>& _Regions) = 0;

        // Dynamic widgets ---------------------------------------------------------
        // Create a widget of a layout type (e.g. "Gitgud/Button") named `widgetId`
        // under `parentId`, wired into the same event routing as layout-declared
        // widgets. Names share one namespace with the layout; creation fails (false)
        // when the name is taken or the parent is missing. Lets Lua build composite
        // rows (file lists with real checkboxes) the XML can't know in advance.
        virtual bool CreateWidget(const std::string& _Type, const std::string& _WidgetId,
            const std::string& _ParentId) = 0;
        // Destroy a widget created with createWidget (or any named widget) and its
        // children. No-op when the widget doesn't exist.
        virtual void DestroyWidget(const std::string& _WidgetId) = 0;
        // Suspend (true) / resume (false) the widget's child re-layout. While
        // suspended, adding or repositioning children does not re-lay-out the
        // siblings — bulk row building goes from O(N^2) to O(N). Resuming
        // performs one full child layout. Always pair suspend with resume.
        virtual void SuspendLayout(const std::string& _WidgetId, bool _bSuspended) = 0;

        // State pull (UI -> app, on demand) --------------------------------------
        // The one exception to "app is the source of truth": interactive text
        // entry (e.g. a commit message box) is owned by the user's typing, so the
        // app reads it back when acting on a raised intent. Returns "" if the
        // widget doesn't exist.
        virtual std::string GetText(const std::string& _WidgetId) const = 0;
        // Selected row of a list widget, 0-based; -1 when nothing is selected.
        virtual int GetSelectedIndex(const std::string& _WidgetId) const = 0;
        // Every selected row (0-based, ascending) — multi-select lists.
        virtual std::vector<int> GetSelectedIndices(const std::string& _WidgetId) const = 0;
        // Any property's current value ("" when the widget/property is missing).
        virtual std::string GetProperty(
            const std::string& _WidgetId, const std::string& _Property) const = 0;
        // True while a text-entry widget (editbox) has keyboard focus, so
        // global shortcuts like Ctrl+Z can leave typing alone.
        virtual bool IsTextInputFocused() const = 0;
        // Absolute rectangle (for anchoring popups); false if the widget is missing.
        virtual bool GetRect(const std::string& _WidgetId, PixelRect& _Out) const = 0;

        // Window-chrome support ---------------------------------------------------
        // True when the point (window coordinates) falls on a widget marked as a
        // move-the-window drag region (layouts opt in per widget; interactive
        // widgets like buttons are never drag regions even inside one). Used by
        // the platform layer's hit test when the app draws its own title bar.
        virtual bool IsDragRegion(float _fX, float _fY) const = 0;

        // Events (UI -> app) ----------------------------------------------------
        // Subscribe once; the backend routes widget interactions here.
        virtual void OnEvent(EventHandler _Handler) = 0;
    };

} // namespace gitgud::ui
