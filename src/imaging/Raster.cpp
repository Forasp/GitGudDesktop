// -----------------------------------------------------------------------------
// Raster — see Raster.h.
// -----------------------------------------------------------------------------

#include "imaging/Raster.h"

#include <algorithm>
#include <cmath>

namespace gitgud::imaging::raster
{

    namespace
    {

        float SegmentDistance(float _fPx, float _fPy, const Point& _A, const Point& _B)
        {
            const float fdx = _B.m_fX - _A.m_fX;
            const float fdy = _B.m_fY - _A.m_fY;
            const float flen2 = fdx * fdx + fdy * fdy;
            float ft = 0.0f;
            if (flen2 > 0.0f)
            {
                ft = ((_fPx - _A.m_fX) * fdx + (_fPy - _A.m_fY) * fdy) / flen2;
                ft = std::clamp(ft, 0.0f, 1.0f);
            }
            const float fcx = _A.m_fX + ft * fdx - _fPx;
            const float fcy = _A.m_fY + ft * fdy - _fPy;
            return std::sqrt(fcx * fcx + fcy * fcy);
        }

        // Signed distance to a rounded rectangle (negative inside).
        float RoundedRectDistance(float _fPx, float _fPy, float _fX, float _fY, float _fWidth,
            float _fHeight, float _fRadius)
        {
            const float fhalfW = _fWidth * 0.5f;
            const float fhalfH = _fHeight * 0.5f;
            const float fradius = std::min({_fRadius, fhalfW, fhalfH});
            const float fqx = std::fabs(_fPx - (_fX + fhalfW)) - (fhalfW - fradius);
            const float fqy = std::fabs(_fPy - (_fY + fhalfH)) - (fhalfH - fradius);
            const float fox = std::max(fqx, 0.0f);
            const float foy = std::max(fqy, 0.0f);
            return std::sqrt(fox * fox + foy * foy) + std::min(std::max(fqx, fqy), 0.0f) - fradius;
        }

        // Pixel bounds of a box, clipped to the image.
        struct Bounds
        {
            int m_iX0 = 0;
            int m_iX1 = -1;
            int m_iY0 = 0;
            int m_iY1 = -1;
        };

        Bounds Clip(const Image& _Img, float _fX0, float _fY0, float _fX1, float _fY1)
        {
            Bounds b;
            b.m_iX0 = std::max(0, static_cast<int>(std::floor(_fX0)) - 1);
            b.m_iY0 = std::max(0, static_cast<int>(std::floor(_fY0)) - 1);
            b.m_iX1 = std::min(_Img.m_iWidth - 1, static_cast<int>(std::ceil(_fX1)) + 1);
            b.m_iY1 = std::min(_Img.m_iHeight - 1, static_cast<int>(std::ceil(_fY1)) + 1);
            return b;
        }

    } // namespace

    Colour FromHex(std::uint32_t _uiRgb)
    {
        return {static_cast<float>((_uiRgb >> 16) & 0xFF) / 255.0f,
            static_cast<float>((_uiRgb >> 8) & 0xFF) / 255.0f,
            static_cast<float>(_uiRgb & 0xFF) / 255.0f};
    }

    Image MakeImage(int _iWidth, int _iHeight, const Colour& _Fill, float _fAlpha)
    {
        Image img;
        img.m_iWidth = std::max(1, _iWidth);
        img.m_iHeight = std::max(1, _iHeight);
        img.m_Rgba.resize(static_cast<std::size_t>(img.m_iWidth) * img.m_iHeight * 4);
        const std::uint8_t r = static_cast<std::uint8_t>(std::lround(_Fill.m_fR * 255.0f));
        const std::uint8_t g = static_cast<std::uint8_t>(std::lround(_Fill.m_fG * 255.0f));
        const std::uint8_t b = static_cast<std::uint8_t>(std::lround(_Fill.m_fB * 255.0f));
        const std::uint8_t a =
            static_cast<std::uint8_t>(std::lround(std::clamp(_fAlpha, 0.0f, 1.0f) * 255.0f));
        for (std::size_t i = 0; i < img.m_Rgba.size(); i += 4)
        {
            img.m_Rgba[i] = r;
            img.m_Rgba[i + 1] = g;
            img.m_Rgba[i + 2] = b;
            img.m_Rgba[i + 3] = a;
        }
        return img;
    }

    void Blend(Image& _Img, int _iX, int _iY, const Colour& _C, float _fAlpha)
    {
        if (_fAlpha <= 0.0f || _iX < 0 || _iY < 0 || _iX >= _Img.m_iWidth || _iY >= _Img.m_iHeight)
        {
            return;
        }
        _fAlpha = std::min(_fAlpha, 1.0f);
        std::uint8_t* pp = &_Img.m_Rgba[(static_cast<std::size_t>(_iY) * _Img.m_iWidth + _iX) * 4];
        const float fdstA = pp[3] / 255.0f;
        const float foutA = _fAlpha + fdstA * (1.0f - _fAlpha);
        if (foutA <= 0.0f)
        {
            return;
        }
        const float fsrc[3] = {_C.m_fR, _C.m_fG, _C.m_fB};
        for (int i = 0; i < 3; ++i)
        {
            const float fdst = pp[i] / 255.0f;
            const float fout = (fsrc[i] * _fAlpha + fdst * fdstA * (1.0f - _fAlpha)) / foutA;
            pp[i] = static_cast<std::uint8_t>(std::lround(std::clamp(fout, 0.0f, 1.0f) * 255.0f));
        }
        pp[3] = static_cast<std::uint8_t>(std::lround(foutA * 255.0f));
    }

    void DrawPolyline(Image& _Img, const std::vector<Point>& _Points, float _fWidth,
        const Colour& _C, float _fOpacity)
    {
        if (_Points.size() < 2)
        {
            return;
        }
        float fminX = _Points[0].m_fX;
        float fmaxX = fminX;
        float fminY = _Points[0].m_fY;
        float fmaxY = fminY;
        for (const Point& p : _Points)
        {
            fminX = std::min(fminX, p.m_fX);
            fmaxX = std::max(fmaxX, p.m_fX);
            fminY = std::min(fminY, p.m_fY);
            fmaxY = std::max(fmaxY, p.m_fY);
        }
        const float fhalf = _fWidth * 0.5f;
        const Bounds b = Clip(_Img, fminX - fhalf, fminY - fhalf, fmaxX + fhalf, fmaxY + fhalf);
        for (int iy = b.m_iY0; iy <= b.m_iY1; ++iy)
        {
            for (int ix = b.m_iX0; ix <= b.m_iX1; ++ix)
            {
                const float fpx = static_cast<float>(ix) + 0.5f;
                const float fpy = static_cast<float>(iy) + 0.5f;
                float fd = 1e9f;
                for (std::size_t i = 0; i + 1 < _Points.size(); ++i)
                {
                    fd = std::min(fd, SegmentDistance(fpx, fpy, _Points[i], _Points[i + 1]));
                }
                Blend(_Img, ix, iy, _C, (fhalf + 0.5f - fd) * _fOpacity);
            }
        }
    }

    void DrawDisc(Image& _Img, const Point& _Centre, float _fRadius, const Colour& _C)
    {
        const Bounds b = Clip(_Img, _Centre.m_fX - _fRadius, _Centre.m_fY - _fRadius,
            _Centre.m_fX + _fRadius, _Centre.m_fY + _fRadius);
        for (int iy = b.m_iY0; iy <= b.m_iY1; ++iy)
        {
            for (int ix = b.m_iX0; ix <= b.m_iX1; ++ix)
            {
                const float fdx = static_cast<float>(ix) + 0.5f - _Centre.m_fX;
                const float fdy = static_cast<float>(iy) + 0.5f - _Centre.m_fY;
                const float fd = std::sqrt(fdx * fdx + fdy * fdy);
                Blend(_Img, ix, iy, _C, _fRadius + 0.5f - fd);
            }
        }
    }

    void DrawRing(
        Image& _Img, const Point& _Centre, float _fRadius, float _fWidth, const Colour& _C)
    {
        const float fouter = _fRadius + _fWidth * 0.5f;
        const Bounds b = Clip(_Img, _Centre.m_fX - fouter, _Centre.m_fY - fouter,
            _Centre.m_fX + fouter, _Centre.m_fY + fouter);
        for (int iy = b.m_iY0; iy <= b.m_iY1; ++iy)
        {
            for (int ix = b.m_iX0; ix <= b.m_iX1; ++ix)
            {
                const float fdx = static_cast<float>(ix) + 0.5f - _Centre.m_fX;
                const float fdy = static_cast<float>(iy) + 0.5f - _Centre.m_fY;
                const float fd = std::fabs(std::sqrt(fdx * fdx + fdy * fdy) - _fRadius);
                Blend(_Img, ix, iy, _C, _fWidth * 0.5f + 0.5f - fd);
            }
        }
    }

    void FillRoundedRect(Image& _Img, float _fX, float _fY, float _fWidth, float _fHeight,
        float _fRadius, const Colour& _C, float _fOpacity)
    {
        const Bounds b = Clip(_Img, _fX, _fY, _fX + _fWidth, _fY + _fHeight);
        for (int iy = b.m_iY0; iy <= b.m_iY1; ++iy)
        {
            for (int ix = b.m_iX0; ix <= b.m_iX1; ++ix)
            {
                const float fd = RoundedRectDistance(static_cast<float>(ix) + 0.5f,
                    static_cast<float>(iy) + 0.5f, _fX, _fY, _fWidth, _fHeight, _fRadius);
                Blend(_Img, ix, iy, _C, std::clamp(0.5f - fd, 0.0f, 1.0f) * _fOpacity);
            }
        }
    }

    void StrokeRoundedRect(Image& _Img, float _fX, float _fY, float _fWidth, float _fHeight,
        float _fRadius, float _fLine, const Colour& _C, float _fOpacity)
    {
        const Bounds b = Clip(_Img, _fX, _fY, _fX + _fWidth, _fY + _fHeight);
        for (int iy = b.m_iY0; iy <= b.m_iY1; ++iy)
        {
            for (int ix = b.m_iX0; ix <= b.m_iX1; ++ix)
            {
                const float fd = RoundedRectDistance(static_cast<float>(ix) + 0.5f,
                    static_cast<float>(iy) + 0.5f, _fX, _fY, _fWidth, _fHeight, _fRadius);
                const float fcoverage = std::clamp(0.5f - fd, 0.0f, 1.0f) -
                                        std::clamp(0.5f - (fd + _fLine), 0.0f, 1.0f);
                Blend(_Img, ix, iy, _C, fcoverage * _fOpacity);
            }
        }
    }

    void FillConvex(
        Image& _Img, const std::vector<Point>& _Points, const Colour& _C, float _fOpacity)
    {
        const std::size_t n = _Points.size();
        if (n < 3)
        {
            return;
        }
        float farea = 0.0f;
        float fminX = _Points[0].m_fX;
        float fmaxX = fminX;
        float fminY = _Points[0].m_fY;
        float fmaxY = fminY;
        for (std::size_t i = 0; i < n; ++i)
        {
            const Point& a = _Points[i];
            const Point& c = _Points[(i + 1) % n];
            farea += a.m_fX * c.m_fY - c.m_fX * a.m_fY;
            fminX = std::min(fminX, a.m_fX);
            fmaxX = std::max(fmaxX, a.m_fX);
            fminY = std::min(fminY, a.m_fY);
            fmaxY = std::max(fmaxY, a.m_fY);
        }
        const float fsign = farea >= 0.0f ? 1.0f : -1.0f;

        const Bounds b = Clip(_Img, fminX, fminY, fmaxX, fmaxY);
        for (int iy = b.m_iY0; iy <= b.m_iY1; ++iy)
        {
            for (int ix = b.m_iX0; ix <= b.m_iX1; ++ix)
            {
                const float fpx = static_cast<float>(ix) + 0.5f;
                const float fpy = static_cast<float>(iy) + 0.5f;
                // Outside distance = the largest signed distance to an edge line.
                float fd = -1e9f;
                for (std::size_t i = 0; i < n; ++i)
                {
                    const Point& a = _Points[i];
                    const Point& c = _Points[(i + 1) % n];
                    const float fex = c.m_fX - a.m_fX;
                    const float fey = c.m_fY - a.m_fY;
                    const float flen = std::sqrt(fex * fex + fey * fey);
                    if (flen <= 0.0f)
                    {
                        continue;
                    }
                    // Outward normal for this winding.
                    const float fnx = fsign * fey / flen;
                    const float fny = -fsign * fex / flen;
                    fd = std::max(fd, (fpx - a.m_fX) * fnx + (fpy - a.m_fY) * fny);
                }
                Blend(_Img, ix, iy, _C, std::clamp(0.5f - fd, 0.0f, 1.0f) * _fOpacity);
            }
        }
    }

    void FillGradientRect(Image& _Img, float _fX, float _fY, float _fWidth, float _fHeight,
        const Colour& _From, float _fFromAlpha, const Colour& _To, float _fToAlpha)
    {
        if (_fWidth <= 0.0f)
        {
            return;
        }
        const Bounds b = Clip(_Img, _fX, _fY, _fX + _fWidth, _fY + _fHeight);
        for (int iy = b.m_iY0; iy <= b.m_iY1; ++iy)
        {
            const float fpy = static_cast<float>(iy) + 0.5f;
            const float fvy =
                std::clamp(std::min(fpy - _fY, _fY + _fHeight - fpy) + 0.5f, 0.0f, 1.0f);
            for (int ix = b.m_iX0; ix <= b.m_iX1; ++ix)
            {
                const float fpx = static_cast<float>(ix) + 0.5f;
                const float fvx =
                    std::clamp(std::min(fpx - _fX, _fX + _fWidth - fpx) + 0.5f, 0.0f, 1.0f);
                const float ft = std::clamp((fpx - _fX) / _fWidth, 0.0f, 1.0f);
                const Colour c{_From.m_fR + (_To.m_fR - _From.m_fR) * ft,
                    _From.m_fG + (_To.m_fG - _From.m_fG) * ft,
                    _From.m_fB + (_To.m_fB - _From.m_fB) * ft};
                const float falpha = _fFromAlpha + (_fToAlpha - _fFromAlpha) * ft;
                Blend(_Img, ix, iy, c, falpha * fvx * fvy);
            }
        }
    }

} // namespace gitgud::imaging::raster
