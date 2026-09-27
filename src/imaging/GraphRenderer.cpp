// -----------------------------------------------------------------------------
// GraphRenderer — see GraphRenderer.h. Shapes are rasterised with a signed
// distance per pixel inside each shape's bounding box, which gives smooth
// edges without a graphics library and stays cheap (a row touches a few
// thousand pixels).
// -----------------------------------------------------------------------------

#include "imaging/GraphRenderer.h"

#include <algorithm>
#include <cmath>

namespace gitgud::imaging
{

    namespace
    {

        struct Point
        {
            float m_fX = 0.0f;
            float m_fY = 0.0f;
        };

        struct Colour
        {
            float m_fR = 0.0f;
            float m_fG = 0.0f;
            float m_fB = 0.0f;
        };

        Colour FromHex(std::uint32_t _uiRgb)
        {
            return {static_cast<float>((_uiRgb >> 16) & 0xFF) / 255.0f,
                static_cast<float>((_uiRgb >> 8) & 0xFF) / 255.0f,
                static_cast<float>(_uiRgb & 0xFF) / 255.0f};
        }

        // Straight-alpha "over" of one pixel.
        void Blend(Image& _Img, int _iX, int _iY, const Colour& _C, float _fAlpha)
        {
            if (_fAlpha <= 0.0f || _iX < 0 || _iY < 0 || _iX >= _Img.m_iWidth ||
                _iY >= _Img.m_iHeight)
            {
                return;
            }
            _fAlpha = std::min(_fAlpha, 1.0f);
            std::uint8_t* pp =
                &_Img.m_Rgba[(static_cast<std::size_t>(_iY) * _Img.m_iWidth + _iX) * 4];
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
                pp[i] =
                    static_cast<std::uint8_t>(std::lround(std::clamp(fout, 0.0f, 1.0f) * 255.0f));
            }
            pp[3] = static_cast<std::uint8_t>(std::lround(foutA * 255.0f));
        }

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

        // A thick anti-aliased polyline (drawn as one shape: no darker joints).
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
            const int ix0 = static_cast<int>(std::floor(fminX - fhalf - 1.0f));
            const int ix1 = static_cast<int>(std::ceil(fmaxX + fhalf + 1.0f));
            const int iy0 = static_cast<int>(std::floor(fminY - fhalf - 1.0f));
            const int iy1 = static_cast<int>(std::ceil(fmaxY + fhalf + 1.0f));
            for (int iy = std::max(iy0, 0); iy <= std::min(iy1, _Img.m_iHeight - 1); ++iy)
            {
                for (int ix = std::max(ix0, 0); ix <= std::min(ix1, _Img.m_iWidth - 1); ++ix)
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
            const int ix0 = static_cast<int>(std::floor(_Centre.m_fX - _fRadius - 1.0f));
            const int ix1 = static_cast<int>(std::ceil(_Centre.m_fX + _fRadius + 1.0f));
            const int iy0 = static_cast<int>(std::floor(_Centre.m_fY - _fRadius - 1.0f));
            const int iy1 = static_cast<int>(std::ceil(_Centre.m_fY + _fRadius + 1.0f));
            for (int iy = std::max(iy0, 0); iy <= std::min(iy1, _Img.m_iHeight - 1); ++iy)
            {
                for (int ix = std::max(ix0, 0); ix <= std::min(ix1, _Img.m_iWidth - 1); ++ix)
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
            const int ix0 = static_cast<int>(std::floor(_Centre.m_fX - fouter - 1.0f));
            const int ix1 = static_cast<int>(std::ceil(_Centre.m_fX + fouter + 1.0f));
            const int iy0 = static_cast<int>(std::floor(_Centre.m_fY - fouter - 1.0f));
            const int iy1 = static_cast<int>(std::ceil(_Centre.m_fY + fouter + 1.0f));
            for (int iy = std::max(iy0, 0); iy <= std::min(iy1, _Img.m_iHeight - 1); ++iy)
            {
                for (int ix = std::max(ix0, 0); ix <= std::min(ix1, _Img.m_iWidth - 1); ++ix)
                {
                    const float fdx = static_cast<float>(ix) + 0.5f - _Centre.m_fX;
                    const float fdy = static_cast<float>(iy) + 0.5f - _Centre.m_fY;
                    const float fd = std::fabs(std::sqrt(fdx * fdx + fdy * fdy) - _fRadius);
                    Blend(_Img, ix, iy, _C, _fWidth * 0.5f + 0.5f - fd);
                }
            }
        }

        // A lane-to-lane edge: straight when the lane doesn't change, an S
        // curve (cubic Bezier with vertical tangents) when it does.
        std::vector<Point> EdgePath(float _fX0, float _fY0, float _fX1, float _fY1)
        {
            if (std::fabs(_fX0 - _fX1) < 0.01f)
            {
                return {{_fX0, _fY0}, {_fX1, _fY1}};
            }
            constexpr int ikSteps = 12;
            const float fdy = _fY1 - _fY0;
            const Point p0{_fX0, _fY0};
            const Point p1{_fX0, _fY0 + fdy * 0.6f};
            const Point p2{_fX1, _fY1 - fdy * 0.6f};
            const Point p3{_fX1, _fY1};
            std::vector<Point> out;
            for (int i = 0; i <= ikSteps; ++i)
            {
                const float ft = static_cast<float>(i) / ikSteps;
                const float fu = 1.0f - ft;
                const float fa = fu * fu * fu;
                const float fb = 3.0f * fu * fu * ft;
                const float fc = 3.0f * fu * ft * ft;
                const float fd = ft * ft * ft;
                out.push_back({fa * p0.m_fX + fb * p1.m_fX + fc * p2.m_fX + fd * p3.m_fX,
                    fa * p0.m_fY + fb * p1.m_fY + fc * p2.m_fY + fd * p3.m_fY});
            }
            return out;
        }

    } // namespace

    int GraphWidth(const GraphStyle& _Style)
    {
        return _Style.m_iPadding * 2 + std::max(1, _Style.m_iLanes) * _Style.m_iLaneWidth;
    }

    Image RenderGraphRows(const std::vector<git::GraphRow>& _Rows,
        const std::vector<std::uint8_t>& _Flags, std::size_t _nFirst, std::size_t _nCount,
        const GraphStyle& _Style)
    {
        Image img;
        img.m_iWidth = GraphWidth(_Style);
        img.m_iHeight = static_cast<int>(_nCount) * _Style.m_iRowHeight;
        img.m_Rgba.assign(static_cast<std::size_t>(img.m_iWidth) * img.m_iHeight * 4, 0);
        if (_Style.m_Colours.empty())
        {
            return img;
        }

        const auto laneX = [&](int _iLane) -> float
        {
            return static_cast<float>(_Style.m_iPadding) +
                   (static_cast<float>(_iLane) + 0.5f) * static_cast<float>(_Style.m_iLaneWidth);
        };
        const auto colourOf = [&](int _iIndex) -> Colour
        {
            const std::size_t n = _Style.m_Colours.size();
            return FromHex(_Style.m_Colours[static_cast<std::size_t>(_iIndex) % n]);
        };
        const Colour background = FromHex(_Style.m_uiBackground);
        const Colour ring = FromHex(_Style.m_uiHeadRing);
        const float frowH = static_cast<float>(_Style.m_iRowHeight);

        for (std::size_t n = 0; n < _nCount && _nFirst + n < _Rows.size(); ++n)
        {
            const git::GraphRow& row = _Rows[_nFirst + n];
            const std::uint8_t uflags = _nFirst + n < _Flags.size() ? _Flags[_nFirst + n] : 0;
            const float ftop = static_cast<float>(n) * frowH;
            const float fmid = ftop + frowH * 0.5f;
            const float fbottom = ftop + frowH;

            // Straight lines first, curves over them, dots on top.
            for (int ipass = 0; ipass < 2; ++ipass)
            {
                for (const git::GraphEdge& edge : row.m_Edges)
                {
                    const bool bstraight = edge.m_iFrom == edge.m_iTo;
                    if (bstraight != (ipass == 0))
                    {
                        continue;
                    }
                    const float fy0 = edge.m_bTop ? ftop : fmid;
                    const float fy1 = edge.m_bTop ? fmid : fbottom;
                    const bool bwipLine = (uflags & kGraphWip) != 0 && !edge.m_bTop;
                    DrawPolyline(img, EdgePath(laneX(edge.m_iFrom), fy0, laneX(edge.m_iTo), fy1),
                        _Style.m_fLineWidth, colourOf(edge.m_iColour), bwipLine ? 0.45f : 1.0f);
                }
            }

            const Point centre{laneX(row.m_iLane), fmid};
            const Colour dot = colourOf(row.m_iColour);
            float fradius = _Style.m_fNodeRadius;
            if (uflags & kGraphMerge)
            {
                fradius *= 0.7f;
            }
            DrawDisc(img, centre, fradius + 1.5f, background);
            if (uflags & kGraphWip)
            {
                DrawRing(img, centre, fradius - 0.5f, 1.8f, dot);
                continue;
            }
            DrawDisc(img, centre, fradius, dot);
            if (uflags & kGraphHead)
            {
                DrawRing(img, centre, fradius + 3.0f, 1.5f, ring);
            }
        }
        return img;
    }

} // namespace gitgud::imaging
