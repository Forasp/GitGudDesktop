// -----------------------------------------------------------------------------
// LuaImageBindings: pictures in a conversation (imaging/ChatImage.h,
// agent/ChatImages.h): what's on the clipboard, and image files shown in
// the UI at a size.
//
//   gitgud.clipboardImage()           -> path, width, height | nil: the
//                                     picture on the clipboard, saved as a
//                                     PNG in the chat-images folder (named
//                                     by its content). Windows only for now
//   gitgud.clipboardHasText()         -> true when the clipboard holds text
//   gitgud.clipboardFiles()           -> { paths }: files copied in a file
//                                     manager (empty when none)
//   gitgud.imageSize(path)            -> width, height | nil, msg: from the
//                                     file's header (png, jpg, gif, bmp...)
//   gitgud.showImage(name, path, maxWidth, maxHeight)
//                                     -> width, height, fullWidth, fullHeight
//                                     | nil, msg: the file decoded, scaled
//                                     down to fit (never up), and published
//                                     as the image `name` (a Gitgud/Image's
//                                     "Image" property). Showing the same
//                                     file at the same size again is free
//   gitgud.drawPicture(name, width, height, shapes)
//                                     -> true | nil, msg: a picture drawn
//                                     from lines and circles (a wiki's
//                                     link graph), published as the image
//                                     `name`, sharp at the display's pixel
//                                     density. Each shape is a table:
//                                       { kind = "line", points = {x1, y1,
//                                         x2, y2, ...}, width, colour }
//                                       { kind = "disc", x, y, radius, colour }
//                                       { kind = "ring", x, y, radius, width,
//                                         colour }
//                                     colour is "AARRGGBB" (the palette's
//                                     form); its alpha is the shape's opacity
// -----------------------------------------------------------------------------

#include <algorithm>
#include <cmath>
#include <condition_variable>
#include <deque>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <tuple>
#include <vector>

#include "agent/ChatImages.h"
#include "app/Profiler.h"
#include "imaging/ChatImage.h"
#include "imaging/Raster.h"
#include "lua/LuaBindings.h"
#include "platform/Shell.h"
#include "ui/IUiBackend.h"

namespace gitgud::lua::bindings
{

    namespace
    {

        namespace fs = std::filesystem;

        bool ReadAll(const std::string& _Path, std::string& _Out)
        {
            std::ifstream in(fs::u8path(_Path), std::ios::binary);
            if (!in)
            {
                return false;
            }
            _Out.assign(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
            return true;
        }

        int LClipboardImage(lua_State* _pL)
        {
            std::string bytes;
            if (!platform::ClipboardImage(bytes))
            {
                lua_pushnil(_pL);
                return 1;
            }
            imaging::Image image;
            std::string error;
            if (!imaging::Decode(bytes, image, error))
            {
                lua_pushnil(_pL);
                return 1;
            }
            // A bitmap goes in as PNG; a PNG as it came.
            if (imaging::SniffMediaType(bytes) != "image/png" && !imaging::EncodePng(image, bytes))
            {
                lua_pushnil(_pL);
                return 1;
            }
            const std::string path = agent::StoreChatImage(bytes, "image/png");
            if (path.empty())
            {
                lua_pushnil(_pL);
                return 1;
            }
            lua_pushstring(_pL, path.c_str());
            lua_pushinteger(_pL, image.m_iWidth);
            lua_pushinteger(_pL, image.m_iHeight);
            return 3;
        }

        int LClipboardHasText(lua_State* _pL)
        {
            lua_pushboolean(_pL, platform::ClipboardHasText());
            return 1;
        }

        int LClipboardFiles(lua_State* _pL)
        {
            const std::vector<std::string> files = platform::ClipboardFiles();
            lua_createtable(_pL, static_cast<int>(files.size()), 0);
            for (std::size_t i = 0; i < files.size(); ++i)
            {
                lua_pushstring(_pL, files[i].c_str());
                lua_rawseti(_pL, -2, static_cast<lua_Integer>(i + 1));
            }
            return 1;
        }

        int LImageSize(lua_State* _pL)
        {
            const std::string path = luaL_checkstring(_pL, 1);
            // The header is near the start; a JPEG's can sit after its EXIF.
            std::ifstream in(fs::u8path(path), std::ios::binary);
            if (!in)
            {
                return FailWith(_pL, "couldn't read " + path);
            }
            std::string head(256 * 1024, '\0');
            in.read(head.data(), static_cast<std::streamsize>(head.size()));
            head.resize(static_cast<std::size_t>(in.gcount()));
            int iwidth = 0;
            int iheight = 0;
            if (!imaging::ReadSize(head, iwidth, iheight))
            {
                return FailWith(_pL, "not an image this app reads");
            }
            lua_pushinteger(_pL, iwidth);
            lua_pushinteger(_pL, iheight);
            return 2;
        }

        // What each name shows now: path, the size asked, and the result.
        struct Shown
        {
            std::string m_Path;
            int m_iMaxWidth = 0;
            int m_iMaxHeight = 0;
            int m_iWidth = 0;
            int m_iHeight = 0;
            int m_iFullWidth = 0;
            int m_iFullHeight = 0;
        };
        std::map<std::string, Shown> g_Shown;

        // Pictures decode on a worker thread (opening a
        // conversation with screenshots froze the app while each was
        // decoded): showImage answers with the size from the file's header
        // and shows a clear picture of that size, and the pixels replace it
        // once decoded (ShowDecodedImages, each frame).
        struct Decode
        {
            std::string m_Name;
            std::string m_Path;
            int m_iMaxWidth = 0;
            int m_iMaxHeight = 0;
            imaging::Image m_Image; // the result (empty: it failed)
        };

        struct Decoder
        {
            std::mutex m_Mutex;
            std::condition_variable m_Wake;
            std::deque<Decode> m_Queue;
            std::vector<Decode> m_Done;
            bool m_bStarted = false;

            void Add(Decode _Job)
            {
                std::lock_guard<std::mutex> lock(m_Mutex);
                m_Queue.push_back(std::move(_Job));
                if (!m_bStarted)
                {
                    m_bStarted = true;
                    // Never joined: it only reads files and lives as long as the app.
                    std::thread([this] { Run(); }).detach();
                }
                m_Wake.notify_one();
            }

            void Run()
            {
                prof::SetThreadName("image decoder");
                for (;;)
                {
                    Decode job;
                    {
                        std::unique_lock<std::mutex> lock(m_Mutex);
                        m_Wake.wait(lock, [this] { return !m_Queue.empty(); });
                        job = std::move(m_Queue.front());
                        m_Queue.pop_front();
                    }
                    {
                        GITGUD_PROFILE_SCOPE("decode a picture");
                        std::string bytes;
                        imaging::Image image;
                        std::string error;
                        if (ReadAll(job.m_Path, bytes) && imaging::Decode(bytes, image, error))
                        {
                            job.m_Image = imaging::Fit(image, job.m_iMaxWidth, job.m_iMaxHeight);
                        }
                    }
                    std::lock_guard<std::mutex> lock(m_Mutex);
                    m_Done.push_back(std::move(job));
                }
            }

            std::vector<Decode> TakeDone()
            {
                std::lock_guard<std::mutex> lock(m_Mutex);
                std::vector<Decode> done;
                done.swap(m_Done);
                return done;
            }
        };

        Decoder& TheDecoder()
        {
            static Decoder* s_pDecoder = new Decoder(); // its thread outlives statics
            return *s_pDecoder;
        }

        // The size Fit gives a picture of this size.
        void FittedSize(int _iWidth, int _iHeight, int _iMaxWidth, int _iMaxHeight, int& _iOutWidth, int& _iOutHeight)
        {
            _iOutWidth = _iWidth;
            _iOutHeight = _iHeight;
            if (_iMaxWidth <= 0 || _iMaxHeight <= 0 || (_iWidth <= _iMaxWidth && _iHeight <= _iMaxHeight))
            {
                return;
            }
            const double fscale = std::min(static_cast<double>(_iMaxWidth) / _iWidth, static_cast<double>(_iMaxHeight) / _iHeight);
            _iOutWidth = std::max(1, static_cast<int>(_iWidth * fscale + 0.5));
            _iOutHeight = std::max(1, static_cast<int>(_iHeight * fscale + 0.5));
        }

        bool HeaderSize(const std::string& _Path, int& _iWidth, int& _iHeight)
        {
            // The header is near the start; a JPEG's can sit after its EXIF.
            std::ifstream in(fs::u8path(_Path), std::ios::binary);
            if (!in)
            {
                return false;
            }
            std::string head(256 * 1024, '\0');
            in.read(head.data(), static_cast<std::streamsize>(head.size()));
            head.resize(static_cast<std::size_t>(in.gcount()));
            return imaging::ReadSize(head, _iWidth, _iHeight) && _iWidth > 0 && _iHeight > 0;
        }

        int PushShown(lua_State* _pL, const Shown& _Shown)
        {
            lua_pushinteger(_pL, _Shown.m_iWidth);
            lua_pushinteger(_pL, _Shown.m_iHeight);
            lua_pushinteger(_pL, _Shown.m_iFullWidth);
            lua_pushinteger(_pL, _Shown.m_iFullHeight);
            return 4;
        }

        int LShowImage(lua_State* _pL)
        {
            const std::string name = luaL_checkstring(_pL, 1);
            const std::string path = luaL_checkstring(_pL, 2);
            const int imaxWidth = static_cast<int>(luaL_checkinteger(_pL, 3));
            const int imaxHeight = static_cast<int>(luaL_checkinteger(_pL, 4));
            auto* pui = Self(_pL)->UiBackend();
            if (!pui)
            {
                return FailWith(_pL, "no UI");
            }
            const auto found = g_Shown.find(name);
            if (found != g_Shown.end() && found->second.m_Path == path &&
                found->second.m_iMaxWidth == imaxWidth && found->second.m_iMaxHeight == imaxHeight)
            {
                return PushShown(_pL, found->second);
            }
            int ifullWidth = 0;
            int ifullHeight = 0;
            if (!fs::exists(fs::u8path(path)))
            {
                return FailWith(_pL, "couldn't read " + path);
            }
            if (!HeaderSize(path, ifullWidth, ifullHeight))
            {
                return FailWith(_pL, "not an image this app reads");
            }
            int iwidth = 0;
            int iheight = 0;
            FittedSize(ifullWidth, ifullHeight, imaxWidth, imaxHeight, iwidth, iheight);
            const std::vector<std::uint8_t> clear(static_cast<std::size_t>(iwidth) * static_cast<std::size_t>(iheight) * 4, 0);
            if (!pui->DefineImage(name, iwidth, iheight, clear))
            {
                return FailWith(_pL, "couldn't show it");
            }
            Shown shown{path, imaxWidth, imaxHeight, iwidth, iheight, ifullWidth, ifullHeight};
            g_Shown[name] = shown;
            TheDecoder().Add(Decode{name, path, imaxWidth, imaxHeight, {}});
            return PushShown(_pL, shown);
        }

        // "AARRGGBB" (or "RRGGBB") -> colour and opacity; white when unreadable.
        void ReadColour(const std::string& _Hex, imaging::raster::Colour& _Out, float& _fAlpha)
        {
            std::uint32_t uvalue = 0xFFFFFFFF;
            try
            {
                uvalue = static_cast<std::uint32_t>(std::stoul(_Hex, nullptr, 16));
            }
            catch (const std::exception&)
            {
            }
            if (_Hex.size() <= 6)
            {
                uvalue |= 0xFF000000u;
            }
            _Out = imaging::raster::FromHex(uvalue & 0xFFFFFFu);
            _fAlpha = static_cast<float>((uvalue >> 24) & 0xFFu) / 255.0f;
        }

        float NumberField(lua_State* _pL, int _iTable, const char* _szKey, float _fDefault)
        {
            lua_getfield(_pL, _iTable, _szKey);
            const float fvalue = lua_isnumber(_pL, -1) ? static_cast<float>(lua_tonumber(_pL, -1)) : _fDefault;
            lua_pop(_pL, 1);
            return fvalue;
        }

        std::string StringField(lua_State* _pL, int _iTable, const char* _szKey)
        {
            lua_getfield(_pL, _iTable, _szKey);
            std::string value = lua_isstring(_pL, -1) ? lua_tostring(_pL, -1) : "";
            lua_pop(_pL, 1);
            return value;
        }

        int LDrawPicture(lua_State* _pL)
        {
            const std::string name = luaL_checkstring(_pL, 1);
            const int iwidth = static_cast<int>(luaL_checkinteger(_pL, 2));
            const int iheight = static_cast<int>(luaL_checkinteger(_pL, 3));
            luaL_checktype(_pL, 4, LUA_TTABLE);
            auto* pui = Self(_pL)->UiBackend();
            if (!pui)
            {
                return FailWith(_pL, "no UI");
            }
            if (iwidth <= 0 || iheight <= 0 || iwidth > 8192 || iheight > 8192)
            {
                return FailWith(_pL, "a picture is 1 to 8192 pixels each way");
            }
            const float fdensity = std::max(1.0f, pui->PixelRatio());
            imaging::Image image = imaging::raster::MakeImage(
                static_cast<int>(std::lround(static_cast<float>(iwidth) * fdensity)),
                static_cast<int>(std::lround(static_cast<float>(iheight) * fdensity)),
                imaging::raster::Colour{}, 0.0f);

            const lua_Integer ncount = luaL_len(_pL, 4);
            for (lua_Integer i = 1; i <= ncount; ++i)
            {
                lua_rawgeti(_pL, 4, i);
                const int ishape = lua_gettop(_pL);
                if (lua_istable(_pL, ishape))
                {
                    const std::string kind = StringField(_pL, ishape, "kind");
                    imaging::raster::Colour colour;
                    float falpha = 1.0f;
                    ReadColour(StringField(_pL, ishape, "colour"), colour, falpha);
                    const float fx = NumberField(_pL, ishape, "x", 0.0f) * fdensity;
                    const float fy = NumberField(_pL, ishape, "y", 0.0f) * fdensity;
                    const float fradius = NumberField(_pL, ishape, "radius", 4.0f) * fdensity;
                    const float fline = NumberField(_pL, ishape, "width", 1.0f) * fdensity;
                    if (kind == "line")
                    {
                        std::vector<imaging::raster::Point> points;
                        lua_getfield(_pL, ishape, "points");
                        if (lua_istable(_pL, -1))
                        {
                            const lua_Integer nvalues = luaL_len(_pL, -1);
                            for (lua_Integer k = 1; k + 1 <= nvalues; k += 2)
                            {
                                lua_rawgeti(_pL, -1, k);
                                lua_rawgeti(_pL, -2, k + 1);
                                points.push_back({static_cast<float>(lua_tonumber(_pL, -2)) * fdensity,
                                    static_cast<float>(lua_tonumber(_pL, -1)) * fdensity});
                                lua_pop(_pL, 2);
                            }
                        }
                        lua_pop(_pL, 1);
                        imaging::raster::DrawPolyline(image, points, fline, colour, falpha);
                    }
                    else if (kind == "disc")
                    {
                        imaging::raster::FillRoundedRect(image, fx - fradius, fy - fradius, fradius * 2.0f,
                            fradius * 2.0f, fradius, colour, falpha);
                    }
                    else if (kind == "ring")
                    {
                        const float fouter = fradius + fline * 0.5f;
                        imaging::raster::StrokeRoundedRect(image, fx - fouter, fy - fouter, fouter * 2.0f,
                            fouter * 2.0f, fouter, fline, colour, falpha);
                    }
                }
                lua_settop(_pL, ishape - 1);
            }

            ui::ImageRegion region;
            region.m_Name = name;
            region.m_iWidth = image.m_iWidth;
            region.m_iHeight = image.m_iHeight;
            if (!pui->DefineImageAtlas(name + "#picture", image.m_iWidth, image.m_iHeight, image.m_Rgba,
                    {region}, fdensity))
            {
                return FailWith(_pL, "couldn't show it");
            }
            lua_pushboolean(_pL, 1);
            return 1;
        }

    } // namespace

    bool ShowDecodedImages(gitgud::ui::IUiBackend* _pUi)
    {
        std::vector<Decode> done = TheDecoder().TakeDone();
        if (done.empty() || !_pUi)
        {
            return false;
        }
        GITGUD_PROFILE_SCOPE("show decoded pictures");
        _pUi->HoldImageRedraws(true);
        for (Decode& job : done)
        {
            // Still showing what was decoded (not another file since).
            const auto it = g_Shown.find(job.m_Name);
            if (job.m_Image.Empty() || it == g_Shown.end() || it->second.m_Path != job.m_Path ||
                it->second.m_iMaxWidth != job.m_iMaxWidth || it->second.m_iMaxHeight != job.m_iMaxHeight)
            {
                continue;
            }
            _pUi->DefineImage(job.m_Name, job.m_Image.m_iWidth, job.m_Image.m_iHeight, job.m_Image.m_Rgba);
        }
        _pUi->HoldImageRedraws(false);
        return true;
    }

    void AddImageBindings(std::vector<luaL_Reg>& _Out)
    {
        _Out.push_back({"clipboardImage", LClipboardImage});
        _Out.push_back({"clipboardHasText", LClipboardHasText});
        _Out.push_back({"clipboardFiles", LClipboardFiles});
        _Out.push_back({"imageSize", LImageSize});
        _Out.push_back({"showImage", LShowImage});
        _Out.push_back({"drawPicture", LDrawPicture});
    }

} // namespace gitgud::lua::bindings
