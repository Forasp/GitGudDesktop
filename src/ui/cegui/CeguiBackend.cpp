#include "ui/cegui/CeguiBackend.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iterator>
#include <string>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

#include <CEGUI/BitmapImage.h>
#include <CEGUI/CEGUI.h>
#include <CEGUI/RendererModules/OpenGL/GL3Renderer.h>
#include <CEGUI/RendererModules/OpenGL/ViewportTarget.h>
#include <CEGUI/views/StandardItemModel.h>
#include <CEGUI/widgets/ButtonBase.h>
#include <CEGUI/widgets/Editbox.h>
#include <CEGUI/widgets/ListWidget.h>
#include <CEGUI/widgets/MultiLineEditbox.h>
#include <CEGUI/widgets/PushButton.h>
#include <CEGUI/widgets/ScrollablePane.h>
#include <CEGUI/widgets/Scrollbar.h>
#include <CEGUI/widgets/Thumb.h>
#include <CEGUI/widgets/ToggleButton.h>

// SDL scancode -> DirectInput keynum table (public domain, copied from
// third_party/cegui/application_templates). CEGUI's Key::Scan values are
// DirectInput keynums. The table needs SDL_NUM_SCANCODES.
#include <SDL_clipboard.h>
#include <SDL_events.h> // SDL_ENABLE / SDL_DISABLE
#include <SDL_mouse.h>
#include <SDL_scancode.h>

#include "ui/cegui/sdl_scancode_to_dinput_mappings.h"

#include "platform/Shell.h"

namespace gitgud::ui
{

    namespace
    {

        // CEGUI was built with its default UTF-32 string class; std::string (UTF-8)
        // converts implicitly on the way in, but needs an explicit conversion out.
        std::string ToStdString(const CEGUI::String& _S)
        {
#if CEGUI_STRING_CLASS == CEGUI_STRING_CLASS_UTF_32
            return CEGUI::String::convertUtf32ToUtf8(_S.c_str());
#else
            return std::string(s.c_str());
#endif
        }

        // FNV-1a over every row, with a separator so ["ab"] != ["a", "b"].
        std::uint64_t HashItems(const std::vector<std::string>& _Items)
        {
            std::uint64_t uihash = 14695981039346656037ull;
            for (const std::string& item : _Items)
            {
                for (const char c : item)
                {
                    uihash = (uihash ^ static_cast<unsigned char>(c)) * 1099511628211ull;
                }
                uihash = (uihash ^ 0xffu) * 1099511628211ull;
            }
            return uihash;
        }

        // Row of a list under a screen position (0-based), or -1.
        int RowAt(CEGUI::ListWidget* _pList, const glm::vec2& _Position)
        {
            const CEGUI::ModelIndex index = _pList->indexAt(_Position);
            auto* pmodel = _pList->getModel();
            if (index.d_modelData == nullptr || !pmodel->isValidIndex(index))
            {
                return -1;
            }
            return pmodel->getChildId(index);
        }

        CEGUI::MouseButton ToCeguiButton(int _iSdlButton)
        {
            // Matches SDL's SDL_BUTTON_LEFT/MIDDLE/RIGHT/X1/X2 numbering (1..5).
            switch (_iSdlButton)
            {
            case 1:
                return CEGUI::MouseButton::Left;
            case 2:
                return CEGUI::MouseButton::Middle;
            case 3:
                return CEGUI::MouseButton::Right;
            case 4:
                return CEGUI::MouseButton::X1;
            case 5:
                return CEGUI::MouseButton::X2;
            default:
                return CEGUI::MouseButton::Invalid;
            }
        }

#if defined(_WIN32)
        // Bridges CEGUI's clipboard to the Windows clipboard (CF_UNICODETEXT), so
        // Ctrl+C/V/X in editboxes interoperates with every other app. CEGUI treats
        // clipboard bytes as UTF-8 "text/plain"; Windows wants UTF-16 — convert at
        // the boundary in both directions.
        class Win32ClipboardProvider final : public CEGUI::NativeClipboardProvider
        {
          public:
            void sendToClipboard(
                const CEGUI::String& _MimeType, void* _pBuffer, size_t _nSize) override
            {
                if (CEGUI::String::convertUtf32ToUtf8(_MimeType.c_str()) != "text/plain")
                {
                    return;
                }
                const int iwideLen = MultiByteToWideChar(CP_UTF8, 0,
                    static_cast<const char*>(_pBuffer), static_cast<int>(_nSize), nullptr, 0);
                HGLOBAL handle = GlobalAlloc(GMEM_MOVEABLE, (iwideLen + 1) * sizeof(wchar_t));
                if (!handle)
                {
                    return;
                }
                auto* pwide = static_cast<wchar_t*>(GlobalLock(handle));
                MultiByteToWideChar(CP_UTF8, 0, static_cast<const char*>(_pBuffer),
                    static_cast<int>(_nSize), pwide, iwideLen);
                pwide[iwideLen] = L'\0';
                GlobalUnlock(handle);

                if (OpenClipboard(nullptr))
                {
                    EmptyClipboard();
                    if (!SetClipboardData(CF_UNICODETEXT, handle))
                    {
                        GlobalFree(handle);
                    }
                    CloseClipboard();
                }
                else
                {
                    GlobalFree(handle);
                }
            }

            void retrieveFromClipboard(
                CEGUI::String& _MimeType, void*& _pBuffer, size_t& _nSize) override
            {
                // CEGUI copies out of `buffer` before the next call, so a member
                // string keeps the bytes alive long enough.
                m_Utf8.clear();
                if (OpenClipboard(nullptr))
                {
                    if (HANDLE handle = GetClipboardData(CF_UNICODETEXT))
                    {
                        if (auto* pwide = static_cast<const wchar_t*>(GlobalLock(handle)))
                        {
                            const int ilen = WideCharToMultiByte(
                                CP_UTF8, 0, pwide, -1, nullptr, 0, nullptr, nullptr);
                            if (ilen > 1)
                            {
                                m_Utf8.resize(ilen - 1); // trim the null terminator
                                WideCharToMultiByte(
                                    CP_UTF8, 0, pwide, -1, m_Utf8.data(), ilen, nullptr, nullptr);
                            }
                            GlobalUnlock(handle);
                        }
                    }
                    CloseClipboard();
                }
                _MimeType = "text/plain";
                _pBuffer = m_Utf8.data();
                _nSize = m_Utf8.size();
            }

          private:
            std::string m_Utf8;
        };
#else
        // Bridges CEGUI's clipboard to SDL's, which speaks X11, Wayland and
        // Cocoa. Both sides use UTF-8.
        class SdlClipboardProvider final : public CEGUI::NativeClipboardProvider
        {
          public:
            void sendToClipboard(
                const CEGUI::String& _MimeType, void* _pBuffer, size_t _nSize) override
            {
                if (CEGUI::String::convertUtf32ToUtf8(_MimeType.c_str()) != "text/plain")
                {
                    return;
                }
                const std::string text(static_cast<const char*>(_pBuffer), _nSize);
                SDL_SetClipboardText(text.c_str());
            }

            void retrieveFromClipboard(
                CEGUI::String& _MimeType, void*& _pBuffer, size_t& _nSize) override
            {
                // CEGUI copies out of `buffer` before the next call, so a member
                // keeps it alive long enough.
                m_Utf8.clear();
                if (char* sztext = SDL_GetClipboardText())
                {
                    m_Utf8 = sztext;
                    SDL_free(sztext);
                }
                _MimeType = "text/plain";
                _pBuffer = m_Utf8.data();
                _nSize = m_Utf8.size();
            }

          private:
            std::string m_Utf8;
        };
#endif // _WIN32

    } // namespace

    CeguiBackend::CeguiBackend() = default;

    CeguiBackend::~CeguiBackend()
    {
        Shutdown();
    }

    bool CeguiBackend::Initialize(
        int _iWindowWidth, int _iWindowHeight, const std::string& _ResourceRoot)
    {
        using namespace CEGUI;

        // CEGUI's default logger writes CEGUI.log into the working directory,
        // which is the user's repository. Create the logger ourselves first
        // (System adopts an existing one) and point it at the logs folder; the
        // exe's folder may be read only (Program Files).
        if (!Logger::getSingletonPtr())
        {
            m_pLogger = new DefaultLogger();
        }
        const std::string logFile = gitgud::platform::LogDirectory() + "/CEGUI.log";
        try
        {
            Logger::getSingleton().setLogFilename(logFile, false);
        }
        catch (const FileIOException&)
        {
            // Not fatal: CEGUI keeps its log in memory instead.
            std::fprintf(stderr, "[cegui] can't write %s\n", logFile.c_str());
        }

#if !defined(_WIN32)
        // CEGUI loads its XML parser, image codec and window renderers at run
        // time, by default from the folder it was installed to on the build
        // machine. An installed GitGud carries them in <app>/lib/cegui-9999.0,
        // or on macOS in the app bundle's Frameworks folder (resources/ is in
        // Contents/Resources).
        {
            const std::string exeDir = _ResourceRoot.substr(0, _ResourceRoot.find_last_of('/'));
#if defined(__APPLE__)
            const std::string moduleDir = exeDir + "/../Frameworks";
#else
            const std::string moduleDir = exeDir + "/lib/cegui-9999.0";
#endif
            std::error_code ec;
            if (!std::getenv("CEGUI_MODULE_DIR") &&
                std::filesystem::is_directory(std::filesystem::u8path(moduleDir), ec))
            {
                setenv("CEGUI_MODULE_DIR", moduleDir.c_str(), 1);
            }
        }
#endif

        m_pRenderer = &OpenGL3Renderer::bootstrapSystem(
            Sizef(static_cast<float>(_iWindowWidth), static_cast<float>(_iWindowHeight)));
        m_pGuiContext =
            &System::getSingleton().createGUIContext(m_pRenderer->getDefaultRenderTarget());
        m_ResourceRoot = _ResourceRoot;

        // Bridge Ctrl+C/V/X to the OS clipboard (CEGUI's is app-internal only
        // until a native provider is set).
#if defined(_WIN32)
        m_ClipboardProvider = std::make_unique<Win32ClipboardProvider>();
#else
        m_ClipboardProvider = std::make_unique<SdlClipboardProvider>();
#endif
        System::getSingleton().getClipboard()->setNativeProvider(m_ClipboardProvider.get());

#ifndef GITGUD_CEGUI_DATAFILES_REL
#error "GITGUD_CEGUI_DATAFILES_REL must be set by CMake when GITGUD_UI_CEGUI is ON"
#endif
        // Prefer the stock data files shipped next to the exe (a packaged build
        // on another machine has no CEGUI install); fall back to the install
        // this build was compiled against (relative to the exe's folder).
        const std::string exeDir = _ResourceRoot.substr(0, _ResourceRoot.find_last_of("/\\"));
        std::string dataDirPath = exeDir + "/cegui-datafiles";
        std::error_code ec;
        if (!std::filesystem::exists(
                std::filesystem::u8path(dataDirPath + "/imagesets/Vanilla.imageset"), ec))
        {
            dataDirPath = exeDir + "/" GITGUD_CEGUI_DATAFILES_REL;
        }
        std::printf("[CeguiBackend] CEGUI data files: %s\n", dataDirPath.c_str());
        const String dataDir(dataDirPath);

        auto* prp =
            static_cast<DefaultResourceProvider*>(System::getSingleton().getResourceProvider());
        prp->setResourceGroupDirectory("schemes", dataDir + "/schemes/");
        prp->setResourceGroupDirectory("imagesets", dataDir + "/imagesets/");
        prp->setResourceGroupDirectory("fonts", dataDir + "/fonts/");
        prp->setResourceGroupDirectory("looknfeels", dataDir + "/looknfeel/");
        prp->setResourceGroupDirectory("schemas", dataDir + "/xml_schemas/");
        // Our own layouts/skin (resources/ is copied next to the exe by CMake; the
        // caller resolves it from the exe location so cwd can be the user's repo).
        prp->setResourceGroupDirectory("layouts", _ResourceRoot + "/layouts/");
        // The GitGud UI's layouts, importable by every UI package (the
        // "layouts" group follows the running package: SetLayoutDirectory).
        prp->setResourceGroupDirectory("gitgud-layouts", _ResourceRoot + "/layouts/");
        prp->setResourceGroupDirectory("gitgud-schemes", _ResourceRoot + "/schemes/");
        prp->setResourceGroupDirectory("gitgud-looknfeel", _ResourceRoot + "/looknfeel/");
        prp->setResourceGroupDirectory("gitgud-fonts", _ResourceRoot + "/fonts/");
        prp->setResourceGroupDirectory("gitgud-imagesets", _ResourceRoot + "/imagesets/");

        ImageManager::setImagesetDefaultResourceGroup("imagesets");
        Font::setDefaultResourceGroup("fonts");
        Scheme::setDefaultResourceGroup("schemes");
        WidgetLookManager::setDefaultResourceGroup("looknfeels");
        WindowManager::setDefaultResourceGroup("layouts");

        XMLParser* parser = System::getSingleton().getXMLParser();
        if (parser->isPropertyPresent("SchemaDefaultResourceGroup"))
        {
            parser->setProperty("SchemaDefaultResourceGroup", "schemas");
        }

        // The Gitgud skin (a dark flat theme) lives in
        // resources/ as plain XML — reskinnable with no recompile. It reuses the
        // Vanilla imageset's brushes from the CEGUI datafiles.
        SchemeManager::getSingleton().createFromFile("Gitgud.xml", "gitgud-schemes");

        // Fonts. Layouts reference these names directly, so every one must
        // exist: prefer the design fonts bundled in resources/fonts (Inter for
        // UI, JetBrains Mono for diffs - both OFL), fall back to the Windows
        // system fonts, then to the DejaVu shipped with CEGUI.
        FontManager& fonts = FontManager::getSingleton();
        // CEGUI's stock definition auto-scales with the window, which
        // re-rasterizes the font and notifies every window of a font change on
        // each step of a resize. Nothing needs it to scale.
        fonts.createFromFile("DejaVuSans-12.font");
        if (fonts.isDefined("DejaVuSans-12"))
        {
            fonts.get("DejaVuSans-12").setAutoScaled(AutoScaledMode::Disabled);
        }
#if defined(_WIN32)
        prp->setResourceGroupDirectory("sysfonts", "C:/Windows/Fonts/");
#endif
        struct FontSpec
        {
            const char* m_szName;
            float m_fSize;
            const char* m_szFile;     // bundled (gitgud-fonts); nullptr = none
            const char* m_szFallback; // Windows system font (sysfonts)
        };

        const FontSpec kFonts[] = {
            {"Gitgud-UI", 13.0f, "Inter-Regular.ttf", "segoeui.ttf"},
            {"Gitgud-UI-Bold", 13.0f, "Inter-SemiBold.ttf", "seguisb.ttf"},
            {"Gitgud-UI-Small", 11.0f, "Inter-Regular.ttf", "segoeui.ttf"},
            {"Gitgud-UI-Title", 16.0f, "Inter-SemiBold.ttf", "seguisb.ttf"},
            {"Gitgud-UI-Large", 21.0f, "Inter-SemiBold.ttf", "seguisb.ttf"},
            {"Gitgud-Mono", 12.0f, "JetBrainsMono-Regular.ttf", "consola.ttf"},
            // The platform's own UI font (Segoe UI on Windows), for skins that
            // imitate native applications.
            {"Gitgud-System", 12.0f, nullptr, "segoeui.ttf"},
            {"Gitgud-System-Bold", 12.0f, nullptr, "seguisb.ttf"},
            {"Gitgud-System-Small", 11.0f, nullptr, "segoeui.ttf"},
        };
        for (const FontSpec& spec : kFonts)
        {
            const std::pair<const char*, const char*> candidates[] = {
                {spec.m_szFile, "gitgud-fonts"},
#if defined(_WIN32)
                {spec.m_szFallback, "sysfonts"},
#endif
                {"DejaVuSans.ttf", "fonts"},
            };
            for (const auto& [szfile, szgroup] : candidates)
            {
                if (!szfile)
                {
                    continue;
                }
                try
                {
                    fonts.createFreeTypeFont(
                        spec.m_szName, spec.m_fSize, FontSizeUnit::Pixels, true, szfile, szgroup);
                    break;
                }
                catch (...)
                {
                    // try the next candidate
                }
            }
        }
        SetUpContext(*m_pGuiContext);

        m_bInitialized = true;
        return true;
    }

    void CeguiBackend::SetUpContext(CEGUI::GUIContext& _Context)
    {
        // CEGUI does NOT install its default key->semantic mappings itself; without
        // this call the semantics table is empty and editboxes never see
        // backspace/delete/arrows/Ctrl+C/V/X (typing still works, which makes the
        // omission easy to miss).
        _Context.initDefaultInputSemantics();
        _Context.setDefaultFont("Gitgud-UI");
        _Context.setDefaultCursorImage("Vanilla-Images/MouseArrow");
        // Without a default tooltip type CEGUI silently ignores every
        // TooltipText property in the layouts.
        _Context.setDefaultTooltipType("Gitgud/Tooltip");
    }

    void CeguiBackend::Shutdown()
    {
        if (!m_bInitialized)
        {
            return;
        }
        if (m_ClipboardProvider)
        {
            CEGUI::System::getSingleton().getClipboard()->setNativeProvider(nullptr);
            m_ClipboardProvider.reset();
        }
        for (auto& [id, surface] : m_Surfaces)
        {
            DestroySurfaceNow(surface);
        }
        m_Surfaces.clear();
        if (m_pGuiContext)
        {
            CEGUI::System::getSingleton().destroyGUIContext(*m_pGuiContext);
            m_pGuiContext = nullptr;
        }
        m_pRootWindow = nullptr;
        m_WidgetCache.clear();
        CEGUI::OpenGL3Renderer::destroySystem();
        m_pRenderer = nullptr;
        delete m_pLogger;
        m_pLogger = nullptr;
        m_bInitialized = false;
    }

    CEGUI::Window* CeguiBackend::LoadLayoutFile(const std::string& _LayoutFile) const
    {
        CEGUI::Window* proot = nullptr;
        try
        {
            proot = CEGUI::WindowManager::getSingleton().loadLayoutFromFile(_LayoutFile);
        }
        catch (const CEGUI::Exception& e)
        {
            std::fprintf(
                stderr, "[CeguiBackend] layout '%s' failed: %s\n", _LayoutFile.c_str(), e.what());
            return nullptr;
        }
        if (!proot)
        {
            std::fprintf(
                stderr, "[CeguiBackend] failed to load layout '%s'\n", _LayoutFile.c_str());
        }
        return proot;
    }

    std::string CeguiBackend::FindNameClash(CEGUI::Window* _pWindow) const
    {
        const std::string name = ToStdString(_pWindow->getName());
        // CEGUI names widgets' internal parts "__auto_..." (the same name in
        // every widget of a type); only user-given names must be unique.
        const bool bautoChild = name.rfind("__auto", 0) == 0;
        if (!bautoChild && m_WidgetCache.count(name) != 0)
        {
            return name;
        }
        for (size_t i = 0; i < _pWindow->getChildCount(); ++i)
        {
            std::string clash = FindNameClash(_pWindow->getChildAtIndex(i));
            if (!clash.empty())
            {
                return clash;
            }
        }
        return {};
    }

    bool CeguiBackend::LoadLayout(const std::string& _LayoutFile)
    {
        CEGUI::Window* proot = LoadLayoutFile(_LayoutFile);
        if (!proot)
        {
            return false;
        }
        // Fresh windows: any previous linkScroll subscriptions died with them.
        // Pop-outs belong to the old UI and go too.
        for (auto& [id, surface] : m_Surfaces)
        {
            DestroySurfaceNow(surface);
        }
        m_Surfaces.clear();
        m_InputSurface.clear();
        m_LinkedScrollPairs.clear();
        m_ScrollLinks.clear();
        m_WidgetCache.clear();
        // Replace (and destroy) any previous root — this is what makes layout
        // hot-reload leak-free.
        if (m_pRootWindow)
        {
            m_pGuiContext->setRootWindow(nullptr);
            CEGUI::WindowManager::getSingleton().destroyWindow(m_pRootWindow);
        }
        m_pRootWindow = proot;
        m_pGuiContext->setRootWindow(proot);
        SubscribeWidgetEvents(proot);
        return true;
    }

    bool CeguiBackend::LoadLayoutInto(const std::string& _LayoutFile, const std::string& _ParentId)
    {
        CEGUI::Window* pparent = FindWidget(_ParentId);
        if (!pparent)
        {
            std::fprintf(stderr, "[CeguiBackend] loadLayout('%s'): no parent '%s'\n",
                _LayoutFile.c_str(), _ParentId.c_str());
            return false;
        }

        CEGUI::Window* pnew = LoadLayoutFile(_LayoutFile);
        if (!pnew)
        {
            return false;
        }

        // Widget names are one global namespace for Lua; refuse a layout that
        // would shadow an existing widget rather than route events ambiguously.
        const std::string clash = FindNameClash(pnew);
        if (!clash.empty())
        {
            std::fprintf(stderr, "[CeguiBackend] layout '%s': widget name '%s' already exists\n",
                _LayoutFile.c_str(), clash.c_str());
            CEGUI::WindowManager::getSingleton().destroyWindow(pnew);
            return false;
        }

        pparent->addChild(pnew);
        SubscribeWidgetEvents(pnew);
        return true;
    }

    void CeguiBackend::SetLayoutDirectory(const std::string& _Directory)
    {
        auto* prp = static_cast<CEGUI::DefaultResourceProvider*>(
            CEGUI::System::getSingleton().getResourceProvider());
        prp->setResourceGroupDirectory("layouts", _Directory + "/");
    }

    void CeguiBackend::ApplySkin(const std::string& _PackageRoot)
    {
        namespace fs = std::filesystem;
        using CEGUI::WidgetLookManager;

        // Every .xml in a package sub-folder, sorted, with a resource group
        // pointing at the folder.
        auto packageFiles = [&](const char* _szSub, const char* _szGroup)
        {
            std::vector<std::string> names;
            if (_PackageRoot.empty())
            {
                return names;
            }
            const std::string dir = _PackageRoot + "/" + _szSub;
            std::error_code ec;
            for (fs::directory_iterator it(fs::u8path(dir), ec), end; !ec && it != end;
                it.increment(ec))
            {
                if (it->is_regular_file(ec) && it->path().extension() == ".xml")
                {
                    names.push_back(it->path().filename().u8string());
                }
            }
            std::sort(names.begin(), names.end());
            auto* prp = static_cast<CEGUI::DefaultResourceProvider*>(
                CEGUI::System::getSingleton().getResourceProvider());
            prp->setResourceGroupDirectory(_szGroup, dir + "/");
            return names;
        };

        // A package's own icons. Imagesets stay loaded once defined (image
        // names are the package's own, so they don't disturb other UIs).
        for (const std::string& file : packageFiles("imagesets", "ui-imagesets"))
        {
            try
            {
                CEGUI::ImageManager::getSingleton().loadImageset(file, "ui-imagesets");
            }
            catch (const CEGUI::Exception& e)
            {
                std::fprintf(
                    stderr, "[CeguiBackend] imageset '%s' failed: %s\n", file.c_str(), e.what());
            }
        }

        const std::vector<std::string> looks = packageFiles("looknfeel", "ui-looknfeel");
        if (looks.empty() && m_SkinOverride.empty())
        {
            return; // the base skin is what's loaded
        }

        // CEGUI's addWidgetLook logs "Replacing previous definition" but
        // keeps the old one (it emplaces), so erase every look a file defines
        // before parsing it. No window is alive to be using them.
        auto parse = [](const std::string& _File, const char* _szGroup, const std::string& _Path)
        {
            std::ifstream in(fs::u8path(_Path), std::ios::binary);
            const std::string xml(
                (std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
            const std::string kLook = "<WidgetLook name=\"";
            for (size_t npos = xml.find(kLook); npos != std::string::npos;
                npos = xml.find(kLook, npos + 1))
            {
                const size_t nstart = npos + kLook.size();
                const size_t nend = xml.find('"', nstart);
                if (nend != std::string::npos)
                {
                    const CEGUI::String name(xml.substr(nstart, nend - nstart));
                    if (WidgetLookManager::getSingleton().isWidgetLookAvailable(name))
                    {
                        WidgetLookManager::getSingleton().eraseWidgetLook(name);
                    }
                }
            }
            try
            {
                WidgetLookManager::getSingleton().parseLookNFeelSpecificationFromFile(
                    _File, _szGroup);
            }
            catch (const CEGUI::Exception& e)
            {
                std::fprintf(
                    stderr, "[CeguiBackend] looknfeel '%s' failed: %s\n", _File.c_str(), e.what());
            }
        };

        // The base looks, in the scheme's order (later files may build on
        // earlier ones), restore anything a previous package redefined.
        std::ifstream scheme(fs::u8path(m_ResourceRoot + "/schemes/Gitgud.xml"), std::ios::binary);
        const std::string schemeText(
            (std::istreambuf_iterator<char>(scheme)), std::istreambuf_iterator<char>());
        const std::string kTag = "<LookNFeel filename=\"";
        for (size_t npos = schemeText.find(kTag); npos != std::string::npos;
            npos = schemeText.find(kTag, npos + 1))
        {
            const size_t nstart = npos + kTag.size();
            const size_t nend = schemeText.find('"', nstart);
            if (nend != std::string::npos)
            {
                const std::string file = schemeText.substr(nstart, nend - nstart);
                parse(file, "gitgud-looknfeel", m_ResourceRoot + "/looknfeel/" + file);
            }
        }

        m_SkinOverride = looks.empty() ? std::string() : _PackageRoot;
        for (const std::string& file : looks)
        {
            parse(file, "ui-looknfeel", _PackageRoot + "/looknfeel/" + file);
        }
    }

    void CeguiBackend::UnloadAll()
    {
        for (auto& [id, surface] : m_Surfaces)
        {
            DestroySurfaceNow(surface);
        }
        m_Surfaces.clear();
        m_InputSurface.clear();
        if (m_pRootWindow)
        {
            m_pGuiContext->setRootWindow(nullptr);
            CEGUI::WindowManager::getSingleton().destroyWindow(m_pRootWindow);
            m_pRootWindow = nullptr;
        }
        // Destroyed windows linger in the dead pool until the next render;
        // flush them now so no window outlives the looks they were built from.
        CEGUI::WindowManager::getSingleton().cleanDeadPool();
        m_LinkedScrollPairs.clear();
        m_ScrollLinks.clear();
        m_WidgetCache.clear();
        m_DragStartRow.clear();
        m_Draggable.clear();
        m_ListFingerprints.clear();
        m_bForceRedraw = true;
    }

    bool CeguiBackend::CreateSurface(
        const std::string& _SurfaceId, int _iWidth, int _iHeight, const std::string& _LayoutFile)
    {
        if (_SurfaceId.empty() || m_Surfaces.count(_SurfaceId) != 0)
        {
            return false;
        }
        CEGUI::Window* proot = LoadLayoutFile(_LayoutFile);
        if (!proot)
        {
            return false;
        }

        // Prefix every user-named widget with the surface id, so two windows
        // built from the same layout (two diffs) keep distinct names.
        const std::string prefix = _SurfaceId + ":";
        std::function<void(CEGUI::Window*)> rename = [&](CEGUI::Window* _pWindow)
        {
            const std::string name = ToStdString(_pWindow->getName());
            if (name.rfind("__auto", 0) != 0)
            {
                _pWindow->setName(prefix + name);
            }
            for (size_t i = 0; i < _pWindow->getChildCount(); ++i)
            {
                rename(_pWindow->getChildAtIndex(i));
            }
        };
        rename(proot);

        const std::string clash = FindNameClash(proot);
        if (!clash.empty())
        {
            std::fprintf(stderr, "[CeguiBackend] surface '%s': widget name '%s' already exists\n",
                _SurfaceId.c_str(), clash.c_str());
            CEGUI::WindowManager::getSingleton().destroyWindow(proot);
            return false;
        }

        Surface surface;
        const CEGUI::Rectf area(
            0.0f, 0.0f, static_cast<float>(_iWidth), static_cast<float>(_iHeight));
        surface.m_pTarget = new CEGUI::OpenGLViewportTarget(*m_pRenderer, area);
        surface.m_pContext = &CEGUI::System::getSingleton().createGUIContext(*surface.m_pTarget);
        SetUpContext(*surface.m_pContext);
        surface.m_pRoot = proot;
        surface.m_pContext->setRootWindow(proot);
        m_Surfaces[_SurfaceId] = surface;
        SubscribeWidgetEvents(proot);
        return true;
    }

    void CeguiBackend::DestroySurfaceNow(Surface& _Surface)
    {
        if (_Surface.m_pContext)
        {
            _Surface.m_pContext->setRootWindow(nullptr);
        }
        if (_Surface.m_pRoot)
        {
            CEGUI::WindowManager::getSingleton().destroyWindow(_Surface.m_pRoot);
            _Surface.m_pRoot = nullptr;
        }
        if (_Surface.m_pContext)
        {
            if (m_pSystemCursorContext == _Surface.m_pContext)
            {
                m_pSystemCursorContext = nullptr;
            }
            CEGUI::System::getSingleton().destroyGUIContext(*_Surface.m_pContext);
            _Surface.m_pContext = nullptr;
        }
        delete _Surface.m_pTarget;
        _Surface.m_pTarget = nullptr;
    }

    void CeguiBackend::DestroySurface(const std::string& _SurfaceId)
    {
        const auto it = m_Surfaces.find(_SurfaceId);
        if (it == m_Surfaces.end())
        {
            return;
        }
        DestroySurfaceNow(it->second);
        m_Surfaces.erase(it);
        if (m_InputSurface == _SurfaceId)
        {
            m_InputSurface.clear();
        }
    }

    void CeguiBackend::ResizeSurface(const std::string& _SurfaceId, int _iWidth, int _iHeight)
    {
        const auto it = m_Surfaces.find(_SurfaceId);
        if (it == m_Surfaces.end())
        {
            return;
        }
        // The context follows its target's area (and re-lays-out its windows).
        it->second.m_pTarget->setArea(
            CEGUI::Rectf(0.0f, 0.0f, static_cast<float>(_iWidth), static_cast<float>(_iHeight)));
        it->second.m_bForceRedraw = true;
    }

    bool CeguiBackend::SurfaceNeedsRedraw(const std::string& _SurfaceId) const
    {
        const auto it = m_Surfaces.find(_SurfaceId);
        return it != m_Surfaces.end() &&
               (it->second.m_bForceRedraw || it->second.m_pContext->isDirty());
    }

    void CeguiBackend::RenderSurface(const std::string& _SurfaceId)
    {
        const auto it = m_Surfaces.find(_SurfaceId);
        if (it == m_Surfaces.end())
        {
            return;
        }
        it->second.m_bForceRedraw = false;
        RenderContext(*it->second.m_pContext);
    }

    void CeguiBackend::RenderContext(CEGUI::GUIContext& _Context)
    {
        m_pRenderer->beginRendering();
        _Context.draw();
        m_pRenderer->endRendering();
        CEGUI::WindowManager::getSingleton().cleanDeadPool();
    }

    void CeguiBackend::SetInputSurface(const std::string& _SurfaceId)
    {
        m_InputSurface = m_Surfaces.count(_SurfaceId) != 0 ? _SurfaceId : std::string();
    }

    CEGUI::GUIContext* CeguiBackend::InputContext() const
    {
        if (!m_InputSurface.empty())
        {
            const auto it = m_Surfaces.find(m_InputSurface);
            if (it != m_Surfaces.end())
            {
                return it->second.m_pContext;
            }
        }
        return m_pGuiContext;
    }

    void CeguiBackend::SetCursorVisible(const std::string& _SurfaceId, bool _bVisible)
    {
        CEGUI::GUIContext* pcontext = m_pGuiContext;
        if (!_SurfaceId.empty())
        {
            const auto it = m_Surfaces.find(_SurfaceId);
            if (it == m_Surfaces.end())
            {
                return;
            }
            pcontext = it->second.m_pContext;
            it->second.m_bForceRedraw = true;
        }
        else
        {
            m_bForceRedraw = true;
        }
        if (pcontext)
        {
            pcontext->setCursorVisible(_bVisible);
        }
    }

    void CeguiBackend::SetPixelRatio(const std::string& _SurfaceId, float _fRatio)
    {
        if (!_SurfaceId.empty())
        {
            const auto it = m_Surfaces.find(_SurfaceId);
            if (it != m_Surfaces.end())
            {
                it->second.m_pTarget->setPixelRatio(_fRatio);
                it->second.m_bForceRedraw = true;
            }
            return;
        }
        m_pRenderer->getDefaultRenderTarget().setPixelRatio(_fRatio);
        m_bForceRedraw = true;
        if (m_pRenderer->getDisplayPixelRatio() == _fRatio)
        {
            return;
        }
        // The fonts rasterise their glyphs again for the new density; every
        // window's cached geometry still uses the old glyph textures.
        m_pRenderer->setDisplayPixelRatio(_fRatio);
        if (m_pRootWindow)
        {
            m_pRootWindow->invalidate(true);
        }
        for (auto& [id, surface] : m_Surfaces)
        {
            surface.m_pRoot->invalidate(true);
            surface.m_bForceRedraw = true;
        }
    }

    float CeguiBackend::PixelRatio() const
    {
        return m_pRenderer ? m_pRenderer->getDisplayPixelRatio() : 1.0f;
    }

    void CeguiBackend::SubscribeWidgetEvents(CEGUI::Window* _pWindow)
    {
        const std::string widgetId = ToStdString(_pWindow->getName());
        CacheWidget(widgetId, _pWindow);

        // CEGUI raises a window (and its whole parent chain) above its siblings
        // whenever it's clicked or focused. Our layouts rely on declared order
        // (placeholders over editboxes, glows behind buttons), so opt out;
        // popups and dialogs are raised explicitly with BringToFront.
        _pWindow->setZOrderingEnabled(false);
        auto raise = [this](const std::string& _Id, const char* _szAction, std::string _Value)
        {
            if (m_EventHandler && !m_bSuppressEvents)
            {
                m_EventHandler(WidgetEvent{_Id, _szAction, std::move(_Value)});
            }
        };

        // Order matters: ToggleButton before PushButton would matter if they were
        // related, but they derive from ButtonBase separately — test both.
        if (auto* ptoggle = dynamic_cast<CEGUI::ToggleButton*>(_pWindow))
        {
            ptoggle->subscribeEvent(CEGUI::ToggleButton::EventSelectStateChanged,
                [this, widgetId, ptoggle, raise](const CEGUI::EventArgs&) -> bool
                {
                    raise(widgetId, "toggled", ptoggle->isSelected() ? "1" : "0");
                    return true;
                });
        }
        else if (auto* pbutton = dynamic_cast<CEGUI::PushButton*>(_pWindow))
        {
            pbutton->subscribeEvent(CEGUI::PushButton::EventClicked,
                [this, widgetId, raise](const CEGUI::EventArgs&) -> bool
                {
                    raise(widgetId, "clicked", "");
                    return true;
                });
        }
        else if (auto* plist = dynamic_cast<CEGUI::ListWidget*>(_pWindow))
        {
            plist->subscribeEvent(CEGUI::ItemView::EventSelectionChanged,
                [this, widgetId, plist, raise](const CEGUI::EventArgs&) -> bool
                {
                    // Report the selected row index (0-based; -1 = cleared).
                    // Read the child id straight from the selection state: item
                    // lookup by StandardItem compares VALUES, so lists with
                    // duplicate row texts would resolve to the first duplicate.
                    int index = -1;
                    const auto& sel = plist->getIndexSelectionStates();
                    if (!sel.empty())
                    {
                        index = static_cast<int>(sel.front().d_childId);
                    }
                    raise(widgetId, "selected", std::to_string(index));
                    return true;
                });
        }
        else if (auto* pedit = dynamic_cast<CEGUI::Editbox*>(_pWindow))
        {
            pedit->subscribeEvent(CEGUI::Editbox::EventTextAccepted,
                [this, widgetId, raise](const CEGUI::EventArgs&) -> bool
                {
                    raise(widgetId, "accepted", "");
                    return true;
                });
            pedit->subscribeEvent(CEGUI::Window::EventTextChanged,
                [this, widgetId, pedit, raise](const CEGUI::EventArgs&) -> bool
                {
                    raise(widgetId, "changed", ToStdString(pedit->getText()));
                    return true;
                });
        }
        else if (auto* pmulti = dynamic_cast<CEGUI::MultiLineEditbox*>(_pWindow))
        {
            pmulti->subscribeEvent(CEGUI::Window::EventTextChanged,
                [this, widgetId, pmulti, raise](const CEGUI::EventArgs&) -> bool
                {
                    raise(widgetId, "changed", ToStdString(pmulti->getText()));
                    return true;
                });
        }
        else if (auto* psb = dynamic_cast<CEGUI::Scrollbar*>(_pWindow))
        {
            // The Falagard scrollbar positions its thumb but never SIZES it, so
            // skins get a fixed-size thumb regardless of content. Resize it
            // proportionally (page/document ratio of the track) whenever the
            // scroll configuration changes.
            psb->subscribeEvent(CEGUI::Scrollbar::EventScrollConfigChanged,
                [psb](const CEGUI::EventArgs&) -> bool
                {
                    CEGUI::Thumb* pthumb = psb->getThumb();
                    if (!pthumb)
                    {
                        return true;
                    }
                    bool bvertical = false;
                    try
                    {
                        bvertical = psb->getProperty("VerticalScrollbar") == "true";
                    }
                    catch (...)
                    {
                    }
                    const float flen =
                        bvertical ? psb->getPixelSize().d_height : psb->getPixelSize().d_width;
                    // The skin may shrink the arrow buttons (Gitgud's are
                    // zero-sized), so measure them instead of assuming squares.
                    float fbuttons = 0.0f;
                    for (CEGUI::Window* pbtn :
                        {static_cast<CEGUI::Window*>(psb->getIncreaseButton()),
                            static_cast<CEGUI::Window*>(psb->getDecreaseButton())})
                    {
                        if (pbtn)
                        {
                            fbuttons += bvertical ? pbtn->getPixelSize().d_height
                                                  : pbtn->getPixelSize().d_width;
                        }
                    }
                    const float ftrack = std::max(0.0f, flen - fbuttons);
                    const float fdoc = psb->getDocumentSize();
                    float fratio = fdoc > 0.0f ? psb->getPageSize() / fdoc : 1.0f;
                    fratio = std::min(1.0f, std::max(0.0f, fratio));
                    const float fsize = std::max(24.0f, ftrack * fratio);
                    if (bvertical)
                    {
                        pthumb->setHeight(cegui_absdim(fsize));
                    }
                    else
                    {
                        pthumb->setWidth(cegui_absdim(fsize));
                    }
                    // updateThumb() is protected; setScrollPosition calls it
                    // unconditionally, so a same-value set re-lays-out the thumb.
                    psb->setScrollPosition(psb->getScrollPosition());
                    return true;
                });
        }

        // Right-click (context menus) and double-click, for every widget. The
        // payload carries the cursor position (for placing a popup) and, on
        // lists, the row under the cursor: "x,y,row" (row = -1 elsewhere).
        auto* plistForRows = dynamic_cast<CEGUI::ListWidget*>(_pWindow);
        _pWindow->subscribeEvent(CEGUI::Window::EventClick,
            [this, widgetId, plistForRows, raise](const CEGUI::EventArgs& _Args) -> bool
            {
                const auto& args = static_cast<const CEGUI::MouseButtonEventArgs&>(_Args);
                const bool bright = args.d_button == CEGUI::MouseButton::Right;
                // Lists also report left clicks with the position, so a row
                // can have zones (e.g. the Changes list's checkbox column).
                const bool blistLeft = plistForRows && args.d_button == CEGUI::MouseButton::Left;
                if (!bright && !blistLeft)
                {
                    return false;
                }
                const int irow = plistForRows ? RowAt(plistForRows, args.d_globalPos) : -1;
                raise(widgetId, bright ? "rightClicked" : "clicked",
                    std::to_string(static_cast<int>(args.d_globalPos.x)) + "," +
                        std::to_string(static_cast<int>(args.d_globalPos.y)) + "," +
                        std::to_string(irow));
                return true;
            });
        // Lists also report drags: press on one row, release on another.
        if (plistForRows)
        {
            // CEGUI only lets the wheel scroll a list whose vertical
            // scrollbar is showing. Lists that hide it (columns scrolled in
            // step with a neighbour, like the commit graph and the diff's
            // hunk gutter) should still scroll under the wheel.
            _pWindow->subscribeEvent(CEGUI::Window::EventScroll,
                [plistForRows](const CEGUI::EventArgs& _Args) -> bool
                {
                    CEGUI::Scrollbar* psb = plistForRows->getVertScrollbar();
                    if (!psb || psb->isEffectiveVisible() ||
                        psb->getDocumentSize() <= psb->getPageSize())
                    {
                        return false;
                    }
                    const auto& args = static_cast<const CEGUI::ScrollEventArgs&>(_Args);
                    psb->setScrollPosition(
                        psb->getScrollPosition() - psb->getStepSize() * args.d_delta);
                    return true;
                });

            _pWindow->subscribeEvent(CEGUI::Window::EventMouseButtonDown,
                [this, widgetId, plistForRows](const CEGUI::EventArgs& _Args) -> bool
                {
                    const auto& args = static_cast<const CEGUI::MouseButtonEventArgs&>(_Args);
                    if (args.d_button == CEGUI::MouseButton::Left)
                    {
                        m_DragStartRow[widgetId] = RowAt(plistForRows, args.d_globalPos);
                    }
                    return false;
                });
            _pWindow->subscribeEvent(CEGUI::Window::EventMouseButtonUp,
                [this, widgetId, plistForRows, raise](const CEGUI::EventArgs& _Args) -> bool
                {
                    const auto& args = static_cast<const CEGUI::MouseButtonEventArgs&>(_Args);
                    if (args.d_button != CEGUI::MouseButton::Left)
                    {
                        return false;
                    }
                    const auto it = m_DragStartRow.find(widgetId);
                    const int ifrom = it != m_DragStartRow.end() ? it->second : -1;
                    m_DragStartRow[widgetId] = -1;
                    const int ito = RowAt(plistForRows, args.d_globalPos);
                    if (ifrom >= 0 && ito >= 0 && ifrom != ito)
                    {
                        raise(
                            widgetId, "dragged", std::to_string(ifrom) + "," + std::to_string(ito));
                    }
                    return false;
                });
        }

        _pWindow->subscribeEvent(CEGUI::Window::EventDoubleClick,
            [this, widgetId, plistForRows, raise](const CEGUI::EventArgs& _Args) -> bool
            {
                const auto& args = static_cast<const CEGUI::MouseButtonEventArgs&>(_Args);
                if (args.d_button != CEGUI::MouseButton::Left)
                {
                    return false;
                }
                const int irow = plistForRows ? RowAt(plistForRows, args.d_globalPos) : -1;
                raise(widgetId, "doubleClicked", std::to_string(irow));
                return true;
            });

        const size_t ncount = _pWindow->getChildCount();
        for (size_t ni = 0; ni < ncount; ++ni)
        {
            if (auto* pchild = dynamic_cast<CEGUI::Window*>(_pWindow->getChildElementAtIndex(ni)))
            {
                SubscribeWidgetEvents(pchild);
            }
        }
    }

    void CeguiBackend::Resize(int _iWindowWidth, int _iWindowHeight)
    {
        CEGUI::System::getSingleton().notifyDisplaySizeChanged(
            CEGUI::Sizef(static_cast<float>(_iWindowWidth), static_cast<float>(_iWindowHeight)));
        m_bForceRedraw = true;
    }

    void CeguiBackend::Update(float _fElapsed)
    {
        CEGUI::System::getSingleton().injectTimePulse(_fElapsed);
        m_pGuiContext->injectTimePulse(_fElapsed);
        for (auto& [id, surface] : m_Surfaces)
        {
            surface.m_pContext->injectTimePulse(_fElapsed);
        }
    }

    bool CeguiBackend::NeedsRedraw() const
    {
        return m_bForceRedraw || (m_pGuiContext && m_pGuiContext->isDirty());
    }

    void CeguiBackend::Render()
    {
        m_bForceRedraw = false;
        RenderContext(*m_pGuiContext);
    }

    void CeguiBackend::InjectMousePosition(float _fX, float _fY)
    {
        InputContext()->injectMousePosition(_fX, _fY);
        UpdateCursorShape();
    }

    void CeguiBackend::InjectMouseButton(int _iButton, bool _bDown)
    {
        const CEGUI::MouseButton mapped = ToCeguiButton(_iButton);
        if (mapped == CEGUI::MouseButton::Invalid)
        {
            return;
        }
        if (_bDown)
        {
            InputContext()->injectMouseButtonDown(mapped);
        }
        else
        {
            InputContext()->injectMouseButtonUp(mapped);
        }
        // A drag ending can leave the mouse over something else.
        UpdateCursorShape();
    }

    void CeguiBackend::InjectMouseScroll(float _fDelta)
    {
        InputContext()->injectMouseWheelChange(_fDelta);
    }

    void CeguiBackend::InjectChar(unsigned int _uiCodepoint)
    {
        InputContext()->injectChar(static_cast<char32_t>(_uiCodepoint));
    }

    void CeguiBackend::InjectKey(int _iSdlScancode, bool _bDown)
    {
        if (_iSdlScancode < 0 || _iSdlScancode >= static_cast<int>(sizeof(scanCodeToKeyNum) /
                                                                   sizeof(scanCodeToKeyNum[0])))
        {
            return;
        }
        const auto scan = static_cast<CEGUI::Key::Scan>(scanCodeToKeyNum[_iSdlScancode]);
        if (scan == CEGUI::Key::Scan::Unknown)
        {
            return;
        }
        if (_bDown)
        {
            InputContext()->injectKeyDown(scan);
        }
        else
        {
            InputContext()->injectKeyUp(scan);
        }
    }

    CEGUI::Window* CeguiBackend::FindWidget(const std::string& _WidgetId) const
    {
        const auto it = m_WidgetCache.find(_WidgetId);
        if (it != m_WidgetCache.end())
        {
            return it->second;
        }
        if (!m_pRootWindow)
        {
            return nullptr;
        }
        // Fallback for windows CEGUI creates lazily behind our back (tooltips,
        // auto-children); cache the hit so the scan happens at most once per id.
        auto* pw = m_pRootWindow->getChildRecursive(_WidgetId);
        if (pw)
        {
            CacheWidget(_WidgetId, pw);
        }
        return pw;
    }

    void CeguiBackend::CacheWidget(const std::string& _WidgetId, CEGUI::Window* _pWindow) const
    {
        if (!m_WidgetCache.emplace(_WidgetId, _pWindow).second)
        {
            // First window wins (duplicate names only occur among CEGUI
            // auto-children); also guards against double subscription.
            return;
        }
        // Destruction cascades child-first through WindowManager::destroyWindow,
        // which fires this per window — so destroying a subtree evicts every
        // cached descendant. The pointer check keeps a stale handler (entry
        // already replaced by a recreated same-name widget) from evicting the
        // new entry.
        _pWindow->subscribeEvent(CEGUI::Window::EventDestructionStarted,
            [this, _WidgetId, _pWindow](const CEGUI::EventArgs&) -> bool
            {
                const auto itDying = m_WidgetCache.find(_WidgetId);
                if (itDying != m_WidgetCache.end() && itDying->second == _pWindow)
                {
                    m_WidgetCache.erase(itDying);
                }
                return true;
            });
    }

    void CeguiBackend::SetText(const std::string& _WidgetId, const std::string& _Text)
    {
        if (auto* pw = FindWidget(_WidgetId))
        {
            // No "changed" echo for text the app itself pushes.
            m_bSuppressEvents = true;
            pw->setText(_Text);
            m_bSuppressEvents = false;
        }
    }

    void CeguiBackend::SetList(const std::string& _WidgetId, const std::vector<std::string>& _Items)
    {
        auto* plist = dynamic_cast<CEGUI::ListWidget*>(FindWidget(_WidgetId));
        if (!plist)
        {
            return;
        }
        // Repopulating clears the selection, which would raise a spurious
        // "selected -1" back at the app — suppress while we mutate.
        m_bSuppressEvents = true;

        // The same rows it already shows: keep the model and its formatted
        // rows, and only clear the selection as a refill would. The count is
        // checked against the list too, so a list recreated at a recycled
        // address never matches a stale fingerprint.
        ListFingerprint fingerprint{HashItems(_Items), _Items.size()};
        const auto known = m_ListFingerprints.find(plist);
        if (known != m_ListFingerprints.end() && known->second.m_uiHash == fingerprint.m_uiHash &&
            known->second.m_uCount == fingerprint.m_uCount &&
            plist->getItemCount() == fingerprint.m_uCount)
        {
            plist->clearSelections();
            m_bSuppressEvents = false;
            return;
        }
        m_ListFingerprints[plist] = fingerprint;

        // ListWidget::addItem notifies the view per row, and the view re-sorts
        // and re-measures its whole item list on every notification — O(N^2)
        // for an N-line diff. Detach the model, fill it silently, and re-attach
        // so the view lays everything out once.
        CEGUI::StandardItemModel* pmodel = plist->getModel();
        const float fscroll = plist->getVertScrollbar()->getScrollPosition();
        plist->setModel(nullptr);
        pmodel->clear(false);
        auto& modelRoot = pmodel->getRoot();
        for (const auto& item : _Items)
        {
            modelRoot.addItem(new CEGUI::StandardItem(item));
        }
        plist->setModel(pmodel);

        // Keep the scroll position across a refill (refreshes shouldn't jump
        // to the top). Measuring now is work the next render would do anyway;
        // it lets the scrollbar clamp against the new content height.
        plist->prepareForRender();
        plist->getVertScrollbar()->setScrollPosition(fscroll);

        m_bSuppressEvents = false;
    }

    void CeguiBackend::SetEnabled(const std::string& _WidgetId, bool _bEnabled)
    {
        if (auto* pw = FindWidget(_WidgetId))
        {
            pw->setEnabled(_bEnabled);
        }
    }

    void CeguiBackend::SetVisible(const std::string& _WidgetId, bool _bVisible)
    {
        if (auto* pw = FindWidget(_WidgetId))
        {
            pw->setVisible(_bVisible);
        }
    }

    void CeguiBackend::SetChecked(const std::string& _WidgetId, bool _bChecked)
    {
        auto* ptoggle = dynamic_cast<CEGUI::ToggleButton*>(FindWidget(_WidgetId));
        if (!ptoggle)
        {
            return;
        }
        m_bSuppressEvents = true;
        ptoggle->setSelected(_bChecked);
        m_bSuppressEvents = false;
    }

    void CeguiBackend::SetProperty(
        const std::string& _WidgetId, const std::string& _Property, const std::string& _Value)
    {
        auto* pw = FindWidget(_WidgetId);
        if (!pw)
        {
            return;
        }
        try
        {
            pw->setProperty(_Property, _Value);
        }
        catch (const CEGUI::Exception& e)
        {
            std::fprintf(stderr, "[CeguiBackend] setProperty('%s','%s') failed: %s\n",
                _WidgetId.c_str(), _Property.c_str(), e.what());
        }
    }

    void CeguiBackend::LinkScroll(const std::string& _WidgetIdA, const std::string& _WidgetIdB)
    {
        auto* pa = dynamic_cast<CEGUI::ListWidget*>(FindWidget(_WidgetIdA));
        auto* pb = dynamic_cast<CEGUI::ListWidget*>(FindWidget(_WidgetIdB));
        if (!pa || !pb)
        {
            return;
        }
        const std::string key = _WidgetIdA + "|" + _WidgetIdB;
        if (std::find(m_LinkedScrollPairs.begin(), m_LinkedScrollPairs.end(), key) !=
            m_LinkedScrollPairs.end())
        {
            return;
        }
        m_LinkedScrollPairs.push_back(key);
        m_ScrollLinks[_WidgetIdA].push_back(_WidgetIdB);
        m_ScrollLinks[_WidgetIdB].push_back(_WidgetIdA);

        // A scroll reaches every list linked to this one, directly or through
        // others (the columns of a table all follow whichever one scrolled).
        auto follow = [this](const std::string& _From, CEGUI::ListWidget* _pFrom)
        {
            _pFrom->getVertScrollbar()->subscribeEvent(CEGUI::Scrollbar::EventScrollPositionChanged,
                [this, _From, _pFrom](const CEGUI::EventArgs&) -> bool
                {
                    if (m_bLinkingScroll)
                    {
                        return true;
                    }
                    m_bLinkingScroll = true;
                    const float fposition = _pFrom->getVertScrollbar()->getScrollPosition();
                    std::vector<std::string> pending{_From};
                    std::vector<std::string> seen{_From};
                    while (!pending.empty())
                    {
                        const std::string id = pending.back();
                        pending.pop_back();
                        for (const std::string& other : m_ScrollLinks[id])
                        {
                            if (std::find(seen.begin(), seen.end(), other) != seen.end())
                            {
                                continue;
                            }
                            seen.push_back(other);
                            pending.push_back(other);
                            if (auto* plist = dynamic_cast<CEGUI::ListWidget*>(FindWidget(other)))
                            {
                                plist->getVertScrollbar()->setScrollPosition(fposition);
                            }
                        }
                    }
                    m_bLinkingScroll = false;
                    return true;
                });
        };
        follow(_WidgetIdA, pa);
        follow(_WidgetIdB, pb);
    }

    bool CeguiBackend::CreateWidget(
        const std::string& _Type, const std::string& _WidgetId, const std::string& _ParentId)
    {
        if (!m_pRootWindow)
        {
            return false;
        }
        // Cache-only duplicate check: FindWidget's fallback would do a full-tree
        // scan for every NEW name — exactly the common case here. The cache holds
        // every layout-declared and app-created widget, so a miss means free.
        if (m_WidgetCache.count(_WidgetId) != 0)
        {
            return false; // name already taken
        }
        auto* parent = _ParentId == ToStdString(m_pRootWindow->getName()) ? m_pRootWindow
                                                                          : FindWidget(_ParentId);
        if (!parent)
        {
            return false;
        }
        CEGUI::Window* pw = nullptr;
        try
        {
            pw = CEGUI::WindowManager::getSingleton().createWindow(_Type, _WidgetId);
        }
        catch (const CEGUI::Exception& e)
        {
            std::fprintf(stderr, "[CeguiBackend] createWidget('%s','%s') failed: %s\n",
                _Type.c_str(), _WidgetId.c_str(), e.what());
            return false;
        }
        parent->addChild(pw);
        SubscribeWidgetEvents(pw);
        return true;
    }

    void CeguiBackend::DestroyWidget(const std::string& _WidgetId)
    {
        auto* pw = FindWidget(_WidgetId);
        if (!pw)
        {
            return;
        }
        // Selection/scroll subscriptions on this window die with it; drop any
        // linkScroll bookkeeping that mentions it so a recreate can re-link.
        m_LinkedScrollPairs.erase(
            std::remove_if(m_LinkedScrollPairs.begin(), m_LinkedScrollPairs.end(),
                [&](const std::string& _Key) { return _Key.find(_WidgetId) != std::string::npos; }),
            m_LinkedScrollPairs.end());
        m_ScrollLinks.erase(_WidgetId);
        for (auto& [id, links] : m_ScrollLinks)
        {
            links.erase(std::remove(links.begin(), links.end(), _WidgetId), links.end());
        }
        CEGUI::WindowManager::getSingleton().destroyWindow(pw);
    }

    void CeguiBackend::SuspendLayout(const std::string& _WidgetId, bool _bSuspended)
    {
        auto* pw = FindWidget(_WidgetId);
        if (!pw)
        {
            return;
        }
        if (_bSuspended)
        {
            pw->beginInitialisation();
        }
        else
        {
            // Runs the deferred child layout exactly once.
            pw->endInitialisation();
        }
    }

    std::string CeguiBackend::GetText(const std::string& _WidgetId) const
    {
        auto* pw = FindWidget(_WidgetId);
        return pw ? ToStdString(pw->getText()) : std::string();
    }

    int CeguiBackend::GetSelectedIndex(const std::string& _WidgetId) const
    {
        auto* plist = dynamic_cast<CEGUI::ListWidget*>(FindWidget(_WidgetId));
        if (!plist)
        {
            return -1;
        }
        // Selection state carries the row directly; resolving through the item
        // would compare item VALUES and mis-report rows with duplicate texts.
        const auto& sel = plist->getIndexSelectionStates();
        return sel.empty() ? -1 : static_cast<int>(sel.front().d_childId);
    }

    void CeguiBackend::SetListItem(
        const std::string& _WidgetId, int _iIndex, const std::string& _Text)
    {
        auto* plist = dynamic_cast<CEGUI::ListWidget*>(FindWidget(_WidgetId));
        if (!plist || _iIndex < 0 || static_cast<size_t>(_iIndex) >= plist->getItemCount())
        {
            return;
        }
        m_ListFingerprints.erase(plist); // no longer what SetList filled in
        m_bSuppressEvents = true;
        plist->getModel()->updateItemText(
            plist->getItemAtIndex(static_cast<size_t>(_iIndex)), _Text);
        m_bSuppressEvents = false;
    }

    void CeguiBackend::SelectListItem(
        const std::string& _WidgetId, int _iIndex, bool _bEnsureVisible)
    {
        auto* plist = dynamic_cast<CEGUI::ListWidget*>(FindWidget(_WidgetId));
        if (!plist)
        {
            return;
        }
        m_bSuppressEvents = true;
        plist->clearSelections();
        if (_iIndex >= 0 && static_cast<size_t>(_iIndex) < plist->getItemCount())
        {
            plist->setIndexSelectionState(static_cast<size_t>(_iIndex), true);
            if (_bEnsureVisible)
            {
                // A list refilled this frame hasn't measured its rows yet, and
                // scrolling to one before that throws out_of_range.
                plist->prepareForRender();
                plist->ensureIndexIsVisible(plist->getItemAtIndex(static_cast<size_t>(_iIndex)));
            }
        }
        m_bSuppressEvents = false;
    }

    void CeguiBackend::SelectListItems(const std::string& _WidgetId, const std::vector<int>& _Rows)
    {
        auto* plist = dynamic_cast<CEGUI::ListWidget*>(FindWidget(_WidgetId));
        if (!plist)
        {
            return;
        }
        m_bSuppressEvents = true;
        plist->clearSelections();
        const bool bmulti = plist->isMultiSelectEnabled();
        plist->setMultiSelectEnabled(true);
        for (const int irow : _Rows)
        {
            if (irow >= 0 && static_cast<size_t>(irow) < plist->getItemCount())
            {
                plist->setIndexSelectionState(static_cast<size_t>(irow), true);
            }
        }
        plist->setMultiSelectEnabled(bmulti);
        m_bSuppressEvents = false;
    }

    std::vector<int> CeguiBackend::GetSelectedIndices(const std::string& _WidgetId) const
    {
        std::vector<int> rows;
        auto* plist = dynamic_cast<CEGUI::ListWidget*>(FindWidget(_WidgetId));
        if (!plist)
        {
            return rows;
        }
        for (const auto& state : plist->getIndexSelectionStates())
        {
            rows.push_back(static_cast<int>(state.d_childId));
        }
        std::sort(rows.begin(), rows.end());
        rows.erase(std::unique(rows.begin(), rows.end()), rows.end());
        return rows;
    }

    void CeguiBackend::SetDraggable(const std::string& _WidgetId, bool _bDraggable)
    {
        CEGUI::Window* pw = FindWidget(_WidgetId);
        if (!pw)
        {
            return;
        }
        if (!_bDraggable)
        {
            m_Draggable.erase(pw);
            return;
        }
        if (m_Draggable.count(pw) != 0)
        {
            return;
        }
        m_Draggable[pw] = false;

        auto raise = [this](const std::string& _Id, const char* _szAction, const glm::vec2& _Pos)
        {
            if (m_EventHandler)
            {
                m_EventHandler(WidgetEvent{_Id, _szAction,
                    std::to_string(static_cast<int>(_Pos.x)) + "," +
                        std::to_string(static_cast<int>(_Pos.y))});
            }
        };
        pw->subscribeEvent(CEGUI::Window::EventMouseButtonDown,
            [this, pw, _WidgetId, raise](const CEGUI::EventArgs& _Args) -> bool
            {
                const auto& args = static_cast<const CEGUI::MouseButtonEventArgs&>(_Args);
                const auto it = m_Draggable.find(pw);
                if (it == m_Draggable.end() || args.d_button != CEGUI::MouseButton::Left)
                {
                    return false;
                }
                it->second = true;
                pw->captureInput();
                raise(_WidgetId, "dragStarted", args.d_globalPos);
                return false;
            });
        pw->subscribeEvent(CEGUI::Window::EventCursorMove,
            [this, pw, _WidgetId, raise](const CEGUI::EventArgs& _Args) -> bool
            {
                const auto it = m_Draggable.find(pw);
                if (it == m_Draggable.end() || !it->second)
                {
                    return false;
                }
                raise(_WidgetId, "dragging",
                    static_cast<const CEGUI::CursorMoveEventArgs&>(_Args).d_globalPos);
                return true;
            });
        pw->subscribeEvent(CEGUI::Window::EventMouseButtonUp,
            [this, pw, _WidgetId, raise](const CEGUI::EventArgs& _Args) -> bool
            {
                const auto it = m_Draggable.find(pw);
                if (it == m_Draggable.end() || !it->second)
                {
                    return false;
                }
                it->second = false;
                pw->releaseInput();
                raise(_WidgetId, "dragEnded",
                    static_cast<const CEGUI::MouseButtonEventArgs&>(_Args).d_globalPos);
                return false;
            });
        pw->subscribeEvent(CEGUI::Window::EventDestructionStarted,
            [this, pw](const CEGUI::EventArgs&) -> bool
            {
                m_Draggable.erase(pw);
                return true;
            });
    }

    void CeguiBackend::SetCursorShape(const std::string& _WidgetId, const std::string& _Shape)
    {
        CEGUI::Window* pw = FindWidget(_WidgetId);
        if (!pw)
        {
            return;
        }
        int ishape = -1;
        if (_Shape == "sizewe")
        {
            ishape = SDL_SYSTEM_CURSOR_SIZEWE;
        }
        else if (_Shape == "sizens")
        {
            ishape = SDL_SYSTEM_CURSOR_SIZENS;
        }
        else if (_Shape == "sizeall")
        {
            ishape = SDL_SYSTEM_CURSOR_SIZEALL;
        }
        else if (_Shape == "hand")
        {
            ishape = SDL_SYSTEM_CURSOR_HAND;
        }
        if (ishape < 0)
        {
            m_CursorShapes.erase(pw);
            return;
        }
        const bool bnew = m_CursorShapes.count(pw) == 0;
        m_CursorShapes[pw] = ishape;
        if (bnew)
        {
            pw->subscribeEvent(CEGUI::Window::EventDestructionStarted,
                [this, pw](const CEGUI::EventArgs&) -> bool
                {
                    m_CursorShapes.erase(pw);
                    return true;
                });
        }
    }

    void CeguiBackend::UpdateCursorShape()
    {
        CEGUI::GUIContext* pcontext = InputContext();
        if (!pcontext)
        {
            return;
        }
        // The widget being dragged keeps its cursor even when the mouse runs
        // ahead of it; otherwise the one under the mouse (or a parent) decides.
        int ishape = -1;
        CEGUI::Window* pw = pcontext->getInputCaptureWindow();
        if (!pw)
        {
            pw = pcontext->getWindowContainingCursor();
        }
        for (; pw && ishape < 0; pw = pw->getParent())
        {
            const auto it = m_CursorShapes.find(pw);
            if (it != m_CursorShapes.end())
            {
                ishape = it->second;
            }
        }

        const auto markDirty = [this](CEGUI::GUIContext* _pContext)
        {
            if (_pContext == m_pGuiContext)
            {
                m_bForceRedraw = true;
                return;
            }
            for (auto& [id, surface] : m_Surfaces)
            {
                if (surface.m_pContext == _pContext)
                {
                    surface.m_bForceRedraw = true;
                }
            }
        };

        if (ishape >= 0)
        {
            // CEGUI sets its own cursor image on every window change; keep
            // it blank while the system cursor shows.
            if (pcontext->getCursorImage())
            {
                pcontext->setCursorImage(nullptr);
                markDirty(pcontext);
            }
            if (ishape != m_iSystemCursor)
            {
                static SDL_Cursor* s_apCursors[SDL_NUM_SYSTEM_CURSORS] = {};
                if (!s_apCursors[ishape])
                {
                    s_apCursors[ishape] =
                        SDL_CreateSystemCursor(static_cast<SDL_SystemCursor>(ishape));
                }
                SDL_SetCursor(s_apCursors[ishape]);
                SDL_ShowCursor(SDL_ENABLE);
            }
            m_iSystemCursor = ishape;
            m_pSystemCursorContext = pcontext;
            return;
        }

        if (m_iSystemCursor >= 0)
        {
            SDL_ShowCursor(SDL_DISABLE); // CEGUI draws the cursor again
            if (m_pSystemCursorContext)
            {
                CEGUI::Window* punder = m_pSystemCursorContext->getWindowContainingCursor();
                m_pSystemCursorContext->setCursorImage(
                    punder ? punder->getEffectiveCursor()
                           : m_pSystemCursorContext->getDefaultCursorImage());
                markDirty(m_pSystemCursorContext);
            }
            m_iSystemCursor = -1;
            m_pSystemCursorContext = nullptr;
        }
    }

    namespace
    {

        CEGUI::Scrollbar* ScrollbarOf(CEGUI::Window* _pWindow, bool _bHorizontal)
        {
            if (auto* pview = dynamic_cast<CEGUI::ItemView*>(_pWindow))
            {
                return _bHorizontal ? pview->getHorzScrollbar() : pview->getVertScrollbar();
            }
            if (auto* ppane = dynamic_cast<CEGUI::ScrollablePane*>(_pWindow))
            {
                return _bHorizontal ? ppane->getHorzScrollbar() : ppane->getVertScrollbar();
            }
            return nullptr;
        }

    } // namespace

    float CeguiBackend::GetScroll(const std::string& _WidgetId, bool _bHorizontal) const
    {
        CEGUI::Scrollbar* psb = ScrollbarOf(FindWidget(_WidgetId), _bHorizontal);
        return psb ? psb->getScrollPosition() : 0.0f;
    }

    void CeguiBackend::SetScroll(const std::string& _WidgetId, float _fPosition, bool _bHorizontal)
    {
        if (CEGUI::Scrollbar* psb = ScrollbarOf(FindWidget(_WidgetId), _bHorizontal))
        {
            psb->setScrollPosition(_fPosition);
        }
    }

    void CeguiBackend::Focus(const std::string& _WidgetId)
    {
        if (auto* pw = FindWidget(_WidgetId))
        {
            pw->activate();
        }
    }

    void CeguiBackend::BringToFront(const std::string& _WidgetId)
    {
        if (auto* pw = FindWidget(_WidgetId))
        {
            // Z-ordering is off for every widget (see SubscribeWidgetEvents);
            // enable it just for this explicit move.
            pw->setZOrderingEnabled(true);
            pw->moveToFront();
            pw->setZOrderingEnabled(false);
        }
    }

    bool CeguiBackend::DefineImage(const std::string& _ImageName, int _iWidth, int _iHeight,
        const std::vector<std::uint8_t>& _Rgba)
    {
        if (_iWidth <= 0 || _iHeight <= 0 ||
            _Rgba.size() < static_cast<size_t>(_iWidth) * static_cast<size_t>(_iHeight) * 4)
        {
            return false;
        }

        try
        {
            const CEGUI::String textureName = "gitgud-texture:" + _ImageName;
            CEGUI::Texture* ptexture = m_pRenderer->isTextureDefined(textureName)
                                           ? &m_pRenderer->getTexture(textureName)
                                           : &m_pRenderer->createTexture(textureName);
            const CEGUI::Sizef size(static_cast<float>(_iWidth), static_cast<float>(_iHeight));
            ptexture->loadFromMemory(_Rgba.data(), size, CEGUI::Texture::PixelFormat::Rgba);

            auto& images = CEGUI::ImageManager::getSingleton();
            if (!images.isDefined(_ImageName))
            {
                images.create("BitmapImage", _ImageName);
            }
            auto& image = static_cast<CEGUI::BitmapImage&>(images.get(_ImageName));
            image.setTexture(ptexture);
            image.setImageArea(CEGUI::Rectf(0.0f, 0.0f, size.d_width, size.d_height));
            image.setAutoScaled(CEGUI::AutoScaledMode::Disabled);
        }
        catch (const CEGUI::Exception& e)
        {
            std::fprintf(stderr, "[CeguiBackend] defineImage('%s') failed: %s\n",
                _ImageName.c_str(), e.what());
            return false;
        }

        // Widgets already showing this image name cached its old geometry.
        InvalidateAll();
        return true;
    }

    bool CeguiBackend::DefineImageAtlas(const std::string& _TextureName, int _iWidth, int _iHeight,
        const std::vector<std::uint8_t>& _Rgba, const std::vector<ImageRegion>& _Regions,
        float _fDensity)
    {
        if (_iWidth <= 0 || _iHeight <= 0 ||
            _Rgba.size() < static_cast<size_t>(_iWidth) * static_cast<size_t>(_iHeight) * 4)
        {
            return false;
        }

        try
        {
            const CEGUI::String textureName = "gitgud-atlas:" + _TextureName;
            CEGUI::Texture* ptexture = m_pRenderer->isTextureDefined(textureName)
                                           ? &m_pRenderer->getTexture(textureName)
                                           : &m_pRenderer->createTexture(textureName);
            const CEGUI::Sizef size(static_cast<float>(_iWidth), static_cast<float>(_iHeight));
            ptexture->loadFromMemory(_Rgba.data(), size, CEGUI::Texture::PixelFormat::Rgba);

            auto& images = CEGUI::ImageManager::getSingleton();
            for (const ImageRegion& region : _Regions)
            {
                if (!images.isDefined(region.m_Name))
                {
                    images.create("BitmapImage", region.m_Name);
                }
                auto& image = static_cast<CEGUI::BitmapImage&>(images.get(region.m_Name));
                image.setTexture(ptexture);
                const float fx = static_cast<float>(region.m_iX);
                const float fy = static_cast<float>(region.m_iY);
                image.setImageArea(CEGUI::Rectf(fx, fy, fx + static_cast<float>(region.m_iWidth),
                    fy + static_cast<float>(region.m_iHeight)));
                image.setAutoScaled(CEGUI::AutoScaledMode::Disabled);
                image.setTexelDensity(_fDensity);
            }
        }
        catch (const CEGUI::Exception& e)
        {
            std::fprintf(stderr, "[CeguiBackend] defineImageAtlas('%s') failed: %s\n",
                _TextureName.c_str(), e.what());
            return false;
        }

        InvalidateAll();
        return true;
    }

    void CeguiBackend::InvalidateAll()
    {
        if (m_pRootWindow)
        {
            m_pRootWindow->invalidate(true);
        }
        for (auto& [id, surface] : m_Surfaces)
        {
            surface.m_pRoot->invalidate(true);
        }
    }

    std::string CeguiBackend::GetProperty(
        const std::string& _WidgetId, const std::string& _Property) const
    {
        auto* pw = FindWidget(_WidgetId);
        if (!pw || !pw->isPropertyPresent(_Property))
        {
            return {};
        }
        try
        {
            return ToStdString(pw->getProperty(_Property));
        }
        catch (const CEGUI::Exception&)
        {
            return {};
        }
    }

    bool CeguiBackend::GetRect(const std::string& _WidgetId, PixelRect& _Out) const
    {
        auto* pw = FindWidget(_WidgetId);
        if (!pw)
        {
            return false;
        }
        const CEGUI::Rectf rect = pw->getUnclippedOuterRect().get();
        _Out.m_fX = rect.left();
        _Out.m_fY = rect.top();
        _Out.m_fWidth = rect.getWidth();
        _Out.m_fHeight = rect.getHeight();
        return true;
    }

    bool CeguiBackend::IsTextInputFocused() const
    {
        CEGUI::GUIContext* pcontext = InputContext();
        if (!pcontext)
        {
            return false;
        }
        CEGUI::Window* pactive = pcontext->getActiveWindow();
        return pactive && pactive->isVisible() &&
               (dynamic_cast<CEGUI::Editbox*>(pactive) ||
                   dynamic_cast<CEGUI::MultiLineEditbox*>(pactive));
    }

    bool CeguiBackend::IsDragRegion(float _fX, float _fY) const
    {
        if (!m_pRootWindow)
        {
            return false;
        }
        // Deepest hit-test-visible widget under the point, then walk up. The first
        // interactive widget wins (its clicks must not turn into window drags);
        // otherwise the first ancestor carrying the layout's AppDrag marker makes
        // the point draggable. Layouts opt in with:
        //   <UserString name="AppDrag" value="true"/>
        CEGUI::Window* pw = m_pRootWindow->getTargetChildAtPosition(glm::vec2(_fX, _fY));
        static const CEGUI::String kAppDrag("AppDrag");
        for (; pw; pw = pw->getParent())
        {
            if (dynamic_cast<CEGUI::ButtonBase*>(pw) || dynamic_cast<CEGUI::Editbox*>(pw) ||
                dynamic_cast<CEGUI::MultiLineEditbox*>(pw) || dynamic_cast<CEGUI::ItemView*>(pw))
            {
                return false;
            }
            if (pw->isUserStringDefined(kAppDrag))
            {
                return ToStdString(pw->getUserString(kAppDrag)) == "true";
            }
        }
        return false;
    }

    void CeguiBackend::OnEvent(EventHandler _Handler)
    {
        m_EventHandler = std::move(_Handler);
    }

} // namespace gitgud::ui
