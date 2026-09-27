// -----------------------------------------------------------------------------
// GraphRenderer — see GraphRenderer.h. The shapes come from imaging/Raster
// (anti-aliased, signed-distance rasterisation).
// -----------------------------------------------------------------------------

#include "imaging/GraphRenderer.h"

#include "imaging/Raster.h"

#include <algorithm>
#include <cmath>

namespace gitgud::imaging
{

    using namespace raster;

    namespace
    {

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
