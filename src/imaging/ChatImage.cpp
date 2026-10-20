#include "imaging/ChatImage.h"

#include <algorithm>
#include <cstring>

// stb_image and stb_image_write are implemented in ImageDiff.cpp.
#include <stb_image.h>
#include <stb_image_write.h>

#define STB_IMAGE_RESIZE_IMPLEMENTATION
#include <stb_image_resize2.h>

namespace gitgud::imaging
{

    namespace
    {

        bool StartsWith(const std::string& _Bytes, const char* _szSig, std::size_t _nOffset = 0)
        {
            const std::size_t n = std::strlen(_szSig);
            return _Bytes.size() >= _nOffset + n && _Bytes.compare(_nOffset, n, _szSig) == 0;
        }

        void AppendTo(void* _pContext, void* _pData, int _iSize)
        {
            static_cast<std::string*>(_pContext)->append(static_cast<const char*>(_pData),
                static_cast<std::size_t>(_iSize));
        }

        constexpr const char* kAlphabet =
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    } // namespace

    std::string SniffMediaType(const std::string& _Bytes)
    {
        if (StartsWith(_Bytes, "\x89PNG\r\n\x1a\n"))
        {
            return "image/png";
        }
        if (StartsWith(_Bytes, "\xff\xd8\xff"))
        {
            return "image/jpeg";
        }
        if (StartsWith(_Bytes, "GIF87a") || StartsWith(_Bytes, "GIF89a"))
        {
            return "image/gif";
        }
        if (StartsWith(_Bytes, "RIFF") && StartsWith(_Bytes, "WEBP", 8))
        {
            return "image/webp";
        }
        return {};
    }

    std::string ExtensionOf(const std::string& _MediaType)
    {
        if (_MediaType == "image/jpeg")
        {
            return "jpg";
        }
        if (_MediaType.rfind("image/", 0) == 0)
        {
            return _MediaType.substr(6);
        }
        return "bin";
    }

    Image Fit(const Image& _In, int _iMaxWidth, int _iMaxHeight)
    {
        if (_In.Empty() || _iMaxWidth <= 0 || _iMaxHeight <= 0 ||
            (_In.m_iWidth <= _iMaxWidth && _In.m_iHeight <= _iMaxHeight))
        {
            return _In;
        }
        const double fscale = std::min(static_cast<double>(_iMaxWidth) / _In.m_iWidth,
            static_cast<double>(_iMaxHeight) / _In.m_iHeight);
        Image out;
        out.m_iWidth = std::max(1, static_cast<int>(_In.m_iWidth * fscale + 0.5));
        out.m_iHeight = std::max(1, static_cast<int>(_In.m_iHeight * fscale + 0.5));
        out.m_Rgba.resize(static_cast<std::size_t>(out.m_iWidth) * out.m_iHeight * 4);
        if (!stbir_resize_uint8_srgb(_In.m_Rgba.data(), _In.m_iWidth, _In.m_iHeight, 0,
                out.m_Rgba.data(), out.m_iWidth, out.m_iHeight, 0, STBIR_RGBA))
        {
            return {};
        }
        return out;
    }

    bool EncodePng(const Image& _Img, std::string& _Out)
    {
        _Out.clear();
        return !_Img.Empty() && stbi_write_png_to_func(AppendTo, &_Out, _Img.m_iWidth, _Img.m_iHeight,
                                    4, _Img.m_Rgba.data(), _Img.m_iWidth * 4) != 0;
    }

    bool EncodeJpeg(const Image& _Img, int _iQuality, std::string& _Out)
    {
        _Out.clear();
        if (_Img.Empty())
        {
            return false;
        }
        // JPEG has no alpha: flatten onto white, as a pasted picture would show.
        std::vector<std::uint8_t> rgb(static_cast<std::size_t>(_Img.m_iWidth) * _Img.m_iHeight * 3);
        for (std::size_t i = 0, j = 0; j < rgb.size(); i += 4, j += 3)
        {
            const unsigned a = _Img.m_Rgba[i + 3];
            for (int c = 0; c < 3; ++c)
            {
                rgb[j + c] = static_cast<std::uint8_t>((_Img.m_Rgba[i + c] * a + 255 * (255 - a)) / 255);
            }
        }
        return stbi_write_jpg_to_func(AppendTo, &_Out, _Img.m_iWidth, _Img.m_iHeight, 3, rgb.data(),
                   _iQuality) != 0;
    }

    bool ReadSize(const std::string& _Bytes, int& _iWidth, int& _iHeight)
    {
        int icomp = 0;
        return stbi_info_from_memory(reinterpret_cast<const stbi_uc*>(_Bytes.data()),
                   static_cast<int>(_Bytes.size()), &_iWidth, &_iHeight, &icomp) != 0;
    }

    std::string Base64Encode(const std::string& _Bytes)
    {
        std::string out;
        out.reserve((_Bytes.size() + 2) / 3 * 4);
        std::size_t i = 0;
        for (; i + 2 < _Bytes.size(); i += 3)
        {
            const unsigned v = (static_cast<unsigned char>(_Bytes[i]) << 16) |
                               (static_cast<unsigned char>(_Bytes[i + 1]) << 8) |
                               static_cast<unsigned char>(_Bytes[i + 2]);
            out += kAlphabet[(v >> 18) & 63];
            out += kAlphabet[(v >> 12) & 63];
            out += kAlphabet[(v >> 6) & 63];
            out += kAlphabet[v & 63];
        }
        if (i < _Bytes.size())
        {
            unsigned v = static_cast<unsigned char>(_Bytes[i]) << 16;
            const bool btwo = i + 1 < _Bytes.size();
            if (btwo)
            {
                v |= static_cast<unsigned char>(_Bytes[i + 1]) << 8;
            }
            out += kAlphabet[(v >> 18) & 63];
            out += kAlphabet[(v >> 12) & 63];
            out += btwo ? kAlphabet[(v >> 6) & 63] : '=';
            out += '=';
        }
        return out;
    }

    bool Base64Decode(const std::string& _Text, std::string& _Out)
    {
        _Out.clear();
        _Out.reserve(_Text.size() / 4 * 3);
        unsigned uacc = 0;
        int ibits = 0;
        for (const char c : _Text)
        {
            if (c == '=')
            {
                break;
            }
            if (c == '\r' || c == '\n' || c == ' ')
            {
                continue;
            }
            const char* pfound = std::strchr(kAlphabet, c);
            if (!pfound || c == '\0')
            {
                return false;
            }
            uacc = (uacc << 6) | static_cast<unsigned>(pfound - kAlphabet);
            ibits += 6;
            if (ibits >= 8)
            {
                ibits -= 8;
                _Out.push_back(static_cast<char>((uacc >> ibits) & 0xFF));
            }
        }
        return true;
    }

    bool PrepareForModel(const std::string& _Bytes, std::string& _MediaType, std::string& _Out,
        std::string& _Error)
    {
        _MediaType = SniffMediaType(_Bytes);
        int iwidth = 0;
        int iheight = 0;
        const bool bsized = ReadSize(_Bytes, iwidth, iheight);
        if (!_MediaType.empty() && _Bytes.size() <= kMaxModelBytes &&
            (!bsized || std::max(iwidth, iheight) <= kMaxModelEdge))
        {
            _Out = _Bytes;
            return true;
        }

        Image decoded;
        if (!Decode(_Bytes, decoded, _Error))
        {
            if (_MediaType.empty())
            {
                _Error = "not an image the model can read";
            }
            return false;
        }
        const Image fitted = Fit(decoded, kMaxModelEdge, kMaxModelEdge);
        if (EncodePng(fitted, _Out) && _Out.size() <= kMaxModelBytes)
        {
            _MediaType = "image/png";
            return true;
        }
        for (const int iquality : {90, 80, 65})
        {
            if (EncodeJpeg(fitted, iquality, _Out) && _Out.size() <= kMaxModelBytes)
            {
                _MediaType = "image/jpeg";
                return true;
            }
        }
        _Error = "the image is too large to send";
        return false;
    }

} // namespace gitgud::imaging
