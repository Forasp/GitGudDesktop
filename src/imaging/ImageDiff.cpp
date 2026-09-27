#include "imaging/ImageDiff.h"

#include <algorithm>
#include <cctype>
#include <cstdlib>

#define STB_IMAGE_IMPLEMENTATION
#define STBI_FAILURE_USERMSG
#include <stb_image.h>

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include <stb_image_write.h>

namespace gitgud::imaging
{

    namespace
    {

        // Refuse absurd images rather than allocating gigabytes of texture.
        constexpr long long kMaxPixels = 64LL * 1024 * 1024;

        constexpr int kCheckerSize = 8;

        // Light/dark checkerboard squares behind transparent pixels.
        void CheckerColour(int _iX, int _iY, std::uint8_t& _R, std::uint8_t& _G, std::uint8_t& _B)
        {
            const bool blight = ((_iX / kCheckerSize) + (_iY / kCheckerSize)) % 2 == 0;
            const std::uint8_t v = blight ? 58 : 42;
            _R = v;
            _G = v;
            _B = v + 8; // a faint purple cast to sit in the Synthwave palette
        }

        // Pixel (x, y) of `_Img` composited over the checkerboard; false when the
        // point is outside the image.
        bool Sample(const Image& _Img, int _iX, int _iY, std::uint8_t _Out[3])
        {
            if (_Img.Empty() || _iX >= _Img.m_iWidth || _iY >= _Img.m_iHeight)
            {
                return false;
            }
            const std::size_t i =
                (static_cast<std::size_t>(_iY) * static_cast<std::size_t>(_Img.m_iWidth) +
                    static_cast<std::size_t>(_iX)) *
                4;
            std::uint8_t cr = 0;
            std::uint8_t cg = 0;
            std::uint8_t cb = 0;
            CheckerColour(_iX, _iY, cr, cg, cb);

            const unsigned a = _Img.m_Rgba[i + 3];
            _Out[0] = static_cast<std::uint8_t>((_Img.m_Rgba[i + 0] * a + cr * (255 - a)) / 255);
            _Out[1] = static_cast<std::uint8_t>((_Img.m_Rgba[i + 1] * a + cg * (255 - a)) / 255);
            _Out[2] = static_cast<std::uint8_t>((_Img.m_Rgba[i + 2] * a + cb * (255 - a)) / 255);
            return true;
        }

        // Raw RGBA equality (transparent pixels compare equal regardless of colour).
        bool SamePixel(const Image& _A, const Image& _B, int _iX, int _iY, int& _iDelta)
        {
            const bool binA = !_A.Empty() && _iX < _A.m_iWidth && _iY < _A.m_iHeight;
            const bool binB = !_B.Empty() && _iX < _B.m_iWidth && _iY < _B.m_iHeight;
            if (!binA || !binB)
            {
                _iDelta = 255;
                return false;
            }
            const std::size_t ia =
                (static_cast<std::size_t>(_iY) * static_cast<std::size_t>(_A.m_iWidth) +
                    static_cast<std::size_t>(_iX)) *
                4;
            const std::size_t ib =
                (static_cast<std::size_t>(_iY) * static_cast<std::size_t>(_B.m_iWidth) +
                    static_cast<std::size_t>(_iX)) *
                4;
            if (_A.m_Rgba[ia + 3] == 0 && _B.m_Rgba[ib + 3] == 0)
            {
                _iDelta = 0;
                return true;
            }
            int idelta = 0;
            for (int c = 0; c < 4; ++c)
            {
                idelta =
                    std::max(idelta, std::abs(int(_A.m_Rgba[ia + c]) - int(_B.m_Rgba[ib + c])));
            }
            _iDelta = idelta;
            return idelta == 0;
        }

        Image Canvas(int _iWidth, int _iHeight)
        {
            Image img;
            img.m_iWidth = _iWidth;
            img.m_iHeight = _iHeight;
            img.m_Rgba.assign(
                static_cast<std::size_t>(_iWidth) * static_cast<std::size_t>(_iHeight) * 4, 0);
            return img;
        }

        void Put(Image& _Img, int _iX, int _iY, std::uint8_t _R, std::uint8_t _G, std::uint8_t _B,
            std::uint8_t _A = 255)
        {
            const std::size_t i =
                (static_cast<std::size_t>(_iY) * static_cast<std::size_t>(_Img.m_iWidth) +
                    static_cast<std::size_t>(_iX)) *
                4;
            _Img.m_Rgba[i + 0] = _R;
            _Img.m_Rgba[i + 1] = _G;
            _Img.m_Rgba[i + 2] = _B;
            _Img.m_Rgba[i + 3] = _A;
        }

    } // namespace

    bool IsImagePath(const std::string& _Path)
    {
        const std::size_t dot = _Path.find_last_of('.');
        if (dot == std::string::npos)
        {
            return false;
        }
        std::string ext = _Path.substr(dot + 1);
        std::transform(ext.begin(), ext.end(), ext.begin(),
            [](unsigned char _C) { return static_cast<char>(std::tolower(_C)); });
        static const char* const kExtensions[] = {
            "png", "jpg", "jpeg", "gif", "bmp", "tga", "psd", "pnm", "ppm", "pgm", "hdr", "pic"};
        for (const char* szext : kExtensions)
        {
            if (ext == szext)
            {
                return true;
            }
        }
        return false;
    }

    bool Decode(const std::string& _Bytes, Image& _Out, std::string& _Error)
    {
        _Out = Image();
        if (_Bytes.empty())
        {
            _Error = "empty file";
            return false;
        }

        int iw = 0;
        int ih = 0;
        int icomp = 0;
        const auto* pbytes = reinterpret_cast<const stbi_uc*>(_Bytes.data());
        const int ilen = static_cast<int>(std::min<std::size_t>(_Bytes.size(), 0x7fffffff));
        if (!stbi_info_from_memory(pbytes, ilen, &iw, &ih, &icomp))
        {
            _Error = stbi_failure_reason() ? stbi_failure_reason() : "unsupported image";
            return false;
        }
        if (static_cast<long long>(iw) * ih > kMaxPixels)
        {
            _Error = "image too large to preview";
            return false;
        }

        stbi_uc* ppixels = stbi_load_from_memory(pbytes, ilen, &iw, &ih, &icomp, 4);
        if (!ppixels)
        {
            _Error = stbi_failure_reason() ? stbi_failure_reason() : "decode failed";
            return false;
        }
        _Out.m_iWidth = iw;
        _Out.m_iHeight = ih;
        _Out.m_Rgba.assign(ppixels, ppixels + static_cast<std::size_t>(iw) * ih * 4);
        stbi_image_free(ppixels);
        return true;
    }

    bool WritePng(const std::string& _Path, const Image& _Image)
    {
        if (_Image.Empty())
        {
            return false;
        }
        return stbi_write_png(_Path.c_str(), _Image.m_iWidth, _Image.m_iHeight, 4,
                   _Image.m_Rgba.data(), _Image.m_iWidth * 4) != 0;
    }

    Comparison Compare(const Image& _Before, const Image& _After, std::uint32_t _uiHighlight)
    {
        Comparison out;
        const int iw =
            std::max(_Before.Empty() ? 0 : _Before.m_iWidth, _After.Empty() ? 0 : _After.m_iWidth);
        const int ih = std::max(
            _Before.Empty() ? 0 : _Before.m_iHeight, _After.Empty() ? 0 : _After.m_iHeight);
        if (iw == 0 || ih == 0)
        {
            return out;
        }

        const std::uint8_t hr = static_cast<std::uint8_t>((_uiHighlight >> 16) & 0xFF);
        const std::uint8_t hg = static_cast<std::uint8_t>((_uiHighlight >> 8) & 0xFF);
        const std::uint8_t hb = static_cast<std::uint8_t>(_uiHighlight & 0xFF);

        out.m_Before = Canvas(iw, ih);
        out.m_After = Canvas(iw, ih);
        out.m_Difference = Canvas(iw, ih);
        out.m_Onion = Canvas(iw, ih);
        out.m_TotalPixels = static_cast<std::size_t>(iw) * static_cast<std::size_t>(ih);

        for (int y = 0; y < ih; ++y)
        {
            for (int x = 0; x < iw; ++x)
            {
                std::uint8_t before[3] = {0, 0, 0};
                std::uint8_t after[3] = {0, 0, 0};
                std::uint8_t checker[3] = {0, 0, 0};
                CheckerColour(x, y, checker[0], checker[1], checker[2]);

                const bool bhasBefore = Sample(_Before, x, y, before);
                const bool bhasAfter = Sample(_After, x, y, after);

                // Outside an image: leave that canvas transparent.
                if (bhasBefore)
                {
                    Put(out.m_Before, x, y, before[0], before[1], before[2]);
                }
                if (bhasAfter)
                {
                    Put(out.m_After, x, y, after[0], after[1], after[2]);
                }

                const std::uint8_t* pb = bhasBefore ? before : checker;
                const std::uint8_t* pa = bhasAfter ? after : checker;
                Put(out.m_Onion, x, y, static_cast<std::uint8_t>((pb[0] + pa[0]) / 2),
                    static_cast<std::uint8_t>((pb[1] + pa[1]) / 2),
                    static_cast<std::uint8_t>((pb[2] + pa[2]) / 2));

                int idelta = 0;
                if (SamePixel(_Before, _After, x, y, idelta))
                {
                    // Unchanged: a dim grey rendition keeps the picture readable
                    // without competing with the highlights.
                    const std::uint8_t* psrc = bhasAfter ? after : before;
                    const int igrey = (psrc[0] * 30 + psrc[1] * 59 + psrc[2] * 11) / 100;
                    const std::uint8_t dim = static_cast<std::uint8_t>(20 + igrey * 35 / 100);
                    Put(out.m_Difference, x, y, dim, dim, static_cast<std::uint8_t>(dim + 6));
                }
                else
                {
                    ++out.m_ChangedPixels;
                    // Scale from 55% to 100% of the highlight by the size of the
                    // change so tiny tweaks still show up.
                    const int iscale = 140 + idelta * 115 / 255;
                    Put(out.m_Difference, x, y, static_cast<std::uint8_t>(hr * iscale / 255),
                        static_cast<std::uint8_t>(hg * iscale / 255),
                        static_cast<std::uint8_t>(hb * iscale / 255));
                }
            }
        }
        return out;
    }

} // namespace gitgud::imaging
