#pragma once

// -----------------------------------------------------------------------------
// CeguiBackend — IUiBackend implementation backed by CEGUI (built from source,
// see third_party/cegui and third_party/cegui-manifest).
//
// This is the v1 bootstrap backend. It wraps CEGUI's OpenGL3 renderer and its
// XML layout loading. Because everything else uses IUiBackend, replacing this
// with a custom renderer later is a drop-in.
// -----------------------------------------------------------------------------

#include "ui/IUiBackend.h"

#include <cstdint>
#include <map>
#include <memory>
#include <unordered_map>

namespace CEGUI
{
    class OpenGL3Renderer;
    class OpenGLViewportTarget;
    class GUIContext;
    class Window;
    class NativeClipboardProvider;
    class Logger;
    class ListWidget;
} // namespace CEGUI

namespace gitgud::ui
{

    class CeguiBackend final : public IUiBackend
    {
      public:
        CeguiBackend();
        ~CeguiBackend() override;

        bool Initialize(
            int _iWindowWidth, int _iWindowHeight, const std::string& _ResourceRoot) override;
        void Shutdown() override;

        bool LoadLayout(const std::string& _LayoutFile) override;
        bool LoadLayoutInto(const std::string& _LayoutFile, const std::string& _ParentId) override;

        void SetLayoutDirectory(const std::string& _Directory) override;
        void ApplySkin(const std::string& _PackageRoot) override;
        void UnloadAll() override;

        bool CreateSurface(const std::string& _SurfaceId, int _iWidth, int _iHeight,
            const std::string& _LayoutFile) override;
        void DestroySurface(const std::string& _SurfaceId) override;
        void ResizeSurface(const std::string& _SurfaceId, int _iWidth, int _iHeight) override;
        bool SurfaceNeedsRedraw(const std::string& _SurfaceId) const override;
        void RenderSurface(const std::string& _SurfaceId) override;
        void SetInputSurface(const std::string& _SurfaceId) override;
        void SetCursorVisible(const std::string& _SurfaceId, bool _bVisible) override;

        void Resize(int _iWindowWidth, int _iWindowHeight) override;
        void Update(float _fElapsed) override;
        bool NeedsRedraw() const override;
        void Render() override;

        void InjectMousePosition(float _fX, float _fY) override;
        void InjectMouseButton(int _iButton, bool _bDown) override;
        void InjectMouseScroll(float _fDelta) override;
        void InjectChar(unsigned int _uiCodepoint) override;
        void InjectKey(int _iSdlScancode, bool _bDown) override;

        void SetText(const std::string& _WidgetId, const std::string& _Text) override;
        void SetList(const std::string& _WidgetId, const std::vector<std::string>& _Items) override;
        void SetEnabled(const std::string& _WidgetId, bool _bEnabled) override;
        void SetVisible(const std::string& _WidgetId, bool _bVisible) override;
        void SetChecked(const std::string& _WidgetId, bool _bChecked) override;
        void SetProperty(const std::string& _WidgetId, const std::string& _Property,
            const std::string& _Value) override;
        void LinkScroll(const std::string& _WidgetIdA, const std::string& _WidgetIdB) override;
        void SetListItem(
            const std::string& _WidgetId, int _iIndex, const std::string& _Text) override;
        void SelectListItem(
            const std::string& _WidgetId, int _iIndex, bool _bEnsureVisible) override;
        void SelectListItems(const std::string& _WidgetId, const std::vector<int>& _Rows) override;
        void SetDraggable(const std::string& _WidgetId, bool _bDraggable) override;
        void SetCursorShape(const std::string& _WidgetId, const std::string& _Shape) override;
        float GetScroll(const std::string& _WidgetId, bool _bHorizontal = false) const override;
        void SetScroll(
            const std::string& _WidgetId, float _fPosition, bool _bHorizontal = false) override;
        void Focus(const std::string& _WidgetId) override;
        void BringToFront(const std::string& _WidgetId) override;
        bool DefineImage(const std::string& _ImageName, int _iWidth, int _iHeight,
            const std::vector<std::uint8_t>& _Rgba) override;
        bool DefineImageAtlas(const std::string& _TextureName, int _iWidth, int _iHeight,
            const std::vector<std::uint8_t>& _Rgba,
            const std::vector<ImageRegion>& _Regions) override;
        bool CreateWidget(const std::string& _Type, const std::string& _WidgetId,
            const std::string& _ParentId) override;
        void DestroyWidget(const std::string& _WidgetId) override;
        void SuspendLayout(const std::string& _WidgetId, bool _bSuspended) override;
        std::string GetText(const std::string& _WidgetId) const override;
        int GetSelectedIndex(const std::string& _WidgetId) const override;
        std::vector<int> GetSelectedIndices(const std::string& _WidgetId) const override;
        std::string GetProperty(
            const std::string& _WidgetId, const std::string& _Property) const override;
        bool GetRect(const std::string& _WidgetId, PixelRect& _Out) const override;
        bool IsTextInputFocused() const override;

        bool IsDragRegion(float _fX, float _fY) const override;

        void OnEvent(EventHandler _Handler) override;

      private:
        // One pop-out window: its own GUI context drawing into a viewport of
        // the shared GL context.
        struct Surface
        {
            CEGUI::OpenGLViewportTarget* m_pTarget = nullptr;
            CEGUI::GUIContext* m_pContext = nullptr;
            CEGUI::Window* m_pRoot = nullptr;
            bool m_bForceRedraw = true;
        };

        void SetUpContext(CEGUI::GUIContext& _Context);
        // Load a layout file; nullptr (logged) on failure.
        CEGUI::Window* LoadLayoutFile(const std::string& _LayoutFile) const;
        // The name of the first widget in the tree already taken, or "".
        std::string FindNameClash(CEGUI::Window* _pWindow) const;
        void DestroySurfaceNow(Surface& _Surface);
        // The context input goes to (the main one unless a surface was chosen).
        CEGUI::GUIContext* InputContext() const;
        void RenderContext(CEGUI::GUIContext& _Context);
        // Drop cached geometry in every window (an image they show changed).
        void InvalidateAll();
        void SubscribeWidgetEvents(CEGUI::Window* _pWindow);
        CEGUI::Window* FindWidget(const std::string& _WidgetId) const;
        void CacheWidget(const std::string& _WidgetId, CEGUI::Window* _pWindow) const;

        // True while WE are pushing state into a widget; suppresses the change
        // events that push would otherwise bounce back into the app.
        bool m_bSuppressEvents = false;

        // linkScroll bookkeeping: already-linked pairs (script hot-reloads call
        // linkScroll again on the same windows) and a reentrancy guard while one
        // side is mirroring the other.
        std::vector<std::string> m_LinkedScrollPairs;
        bool m_bLinkingScroll = false;
        // Every list's linked neighbours; a scroll reaches the whole group.
        std::unordered_map<std::string, std::vector<std::string>> m_ScrollLinks;

        // Widget-id -> window index. getChildRecursive is an O(tree) UTF-32
        // string scan, which made bulk row building O(N^2); this map makes every
        // lookup O(1). Populated for the whole tree on layout load and on widget
        // creation; entries self-evict via EventDestructionStarted. mutable:
        // FindWidget is const but caches fallback hits.
        mutable std::unordered_map<std::string, CEGUI::Window*> m_WidgetCache;

        // List row under the left button when it went down (drag detection),
        // per list widget; -1 when none.
        std::unordered_map<std::string, int> m_DragStartRow;

        // Widgets opted into drag events (SetDraggable), and whether each is
        // mid-drag. Keyed by window so a recreated widget subscribes afresh.
        std::unordered_map<CEGUI::Window*, bool> m_Draggable;

        // System cursor shapes asked for per widget (SetCursorShape), as SDL
        // system cursor ids, and the one showing now (-1: CEGUI's own cursor).
        std::unordered_map<CEGUI::Window*, int> m_CursorShapes;
        int m_iSystemCursor = -1;
        CEGUI::GUIContext* m_pSystemCursorContext = nullptr;
        // Show the system cursor over (or while dragging) a widget that asked
        // for one, and CEGUI's cursor everywhere else. Called after mouse input.
        void UpdateCursorShape();

        // What each list was last filled with by SetList: a hash of the rows
        // and their count. Refreshes often push identical rows; matching ones
        // skip the model rebuild and the re-format of every row.
        struct ListFingerprint
        {
            std::uint64_t m_uiHash = 0;
            std::size_t m_uCount = 0;
        };

        std::unordered_map<CEGUI::ListWidget*, ListFingerprint> m_ListFingerprints;

        EventHandler m_EventHandler;
        CEGUI::OpenGL3Renderer* m_pRenderer = nullptr;
        CEGUI::GUIContext* m_pGuiContext = nullptr;
        CEGUI::Window* m_pRootWindow = nullptr;
        std::map<std::string, Surface> m_Surfaces;
        std::string m_InputSurface; // "" = the main window
        std::string m_ResourceRoot;
        std::string m_SkinOverride; // package whose looknfeel is applied over the base skin
        // OS clipboard bridge (Windows today); CEGUI does not take ownership.
        std::unique_ptr<CEGUI::NativeClipboardProvider> m_ClipboardProvider;
        // Created before CEGUI's System so its log lands in platform::LogDirectory().
        CEGUI::Logger* m_pLogger = nullptr;
        bool m_bInitialized = false;
        // Set when something outside CEGUI's own dirty tracking (a resize)
        // requires a fresh frame.
        bool m_bForceRedraw = true;
    };

} // namespace gitgud::ui
