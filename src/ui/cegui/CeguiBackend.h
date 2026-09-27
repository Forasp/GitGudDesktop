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

#include <memory>
#include <unordered_map>

namespace CEGUI
{
    class OpenGL3Renderer;
    class GUIContext;
    class Window;
    class NativeClipboardProvider;
    class Logger;
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
        float GetScroll(const std::string& _WidgetId) const override;
        void SetScroll(const std::string& _WidgetId, float _fPosition) override;
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
        std::string GetProperty(
            const std::string& _WidgetId, const std::string& _Property) const override;
        bool GetRect(const std::string& _WidgetId, PixelRect& _Out) const override;
        bool IsTextInputFocused() const override;

        bool IsDragRegion(float _fX, float _fY) const override;

        void OnEvent(EventHandler _Handler) override;

      private:
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

        // Widget-id -> window index. getChildRecursive is an O(tree) UTF-32
        // string scan, which made bulk row building O(N^2); this map makes every
        // lookup O(1). Populated for the whole tree on layout load and on widget
        // creation; entries self-evict via EventDestructionStarted. mutable:
        // FindWidget is const but caches fallback hits.
        mutable std::unordered_map<std::string, CEGUI::Window*> m_WidgetCache;

        // List row under the left button when it went down (drag detection),
        // per list widget; -1 when none.
        std::unordered_map<std::string, int> m_DragStartRow;

        EventHandler m_EventHandler;
        CEGUI::OpenGL3Renderer* m_pRenderer = nullptr;
        CEGUI::GUIContext* m_pGuiContext = nullptr;
        CEGUI::Window* m_pRootWindow = nullptr;
        // OS clipboard bridge (Windows today); CEGUI does not take ownership.
        std::unique_ptr<CEGUI::NativeClipboardProvider> m_ClipboardProvider;
        // Created before CEGUI's System so its log lands next to the exe.
        CEGUI::Logger* m_pLogger = nullptr;
        bool m_bInitialized = false;
        // Set when something outside CEGUI's own dirty tracking (a resize)
        // requires a fresh frame.
        bool m_bForceRedraw = true;
    };

} // namespace gitgud::ui
