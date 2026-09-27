// -----------------------------------------------------------------------------
// RevisionGraphRenderer — see RevisionGraphRenderer.h.
// -----------------------------------------------------------------------------

#include "imaging/RevisionGraphRenderer.h"

#include <algorithm>
#include <cmath>

#include "imaging/Raster.h"

namespace gitgud::imaging
{

    using namespace raster;

    namespace
    {

        // GL textures top out around 16k pixels on common hardware.
        constexpr int ikMaxTexture = 16000;

        // An arrow from `_From` to `_To`, its head touching `_To`.
        void DrawArrow(Image& _Img, const Point& _From, const Point& _To, const Colour& _C,
            float _fWidth, float _fHead)
        {
            const float fdx = _To.m_fX - _From.m_fX;
            const float fdy = _To.m_fY - _From.m_fY;
            const float flen = std::sqrt(fdx * fdx + fdy * fdy);
            if (flen < 1.0f)
            {
                return;
            }
            const float fux = fdx / flen;
            const float fuy = fdy / flen;
            const Point base{_To.m_fX - fux * _fHead, _To.m_fY - fuy * _fHead};
            DrawPolyline(_Img, {_From, base}, _fWidth, _C, 1.0f);
            const float fhalf = _fHead * 0.45f;
            FillConvex(_Img,
                {_To, {base.m_fX - fuy * fhalf, base.m_fY + fux * fhalf},
                    {base.m_fX + fuy * fhalf, base.m_fY - fux * fhalf}},
                _C, 1.0f);
        }

        // The box outline for a revision: a rectangle, with the left end
        // rounded (added), pointed (merged in), or slanted (branched).
        std::vector<Point> BoxShape(const PixelBox& _B, char _cShape)
        {
            const float fx0 = _B.m_fX;
            const float fy0 = _B.m_fY;
            const float fx1 = _B.m_fX + _B.m_fWidth;
            const float fy1 = _B.m_fY + _B.m_fHeight;
            const float fmid = (fy0 + fy1) * 0.5f;
            const float fcut = std::min(_B.m_fHeight * 0.45f, _B.m_fWidth * 0.3f);
            switch (_cShape)
            {
            case 'I': // pointed left end
                return {{fx0, fmid}, {fx0 + fcut, fy0}, {fx1, fy0}, {fx1, fy1}, {fx0 + fcut, fy1}};
            case 'B': // slanted left end
                return {{fx0 + fcut, fy0}, {fx1, fy0}, {fx1, fy1}, {fx0, fy1}};
            default:
                return {{fx0, fy0}, {fx1, fy0}, {fx1, fy1}, {fx0, fy1}};
            }
        }

        void DrawBox(Image& _Img, const PixelBox& _B, char _cShape, const Colour& _Body,
            const Colour& _Head, const Colour& _Border)
        {
            const float fheadW = std::max(14.0f, _B.m_fWidth * 0.42f);
            if (_cShape == 'A')
            {
                // Rounded left end: a pill, with its right end squared off.
                const float fr = _B.m_fHeight * 0.5f;
                FillRoundedRect(_Img, _B.m_fX, _B.m_fY, _B.m_fWidth, _B.m_fHeight, fr, _Body, 1.0f);
                FillRoundedRect(
                    _Img, _B.m_fX + fr, _B.m_fY, _B.m_fWidth - fr, _B.m_fHeight, 0.0f, _Body, 1.0f);
                FillRoundedRect(_Img, _B.m_fX, _B.m_fY, fheadW + fr, _B.m_fHeight, fr, _Head, 1.0f);
                FillRoundedRect(
                    _Img, _B.m_fX + fr, _B.m_fY, fheadW, _B.m_fHeight, 0.0f, _Head, 1.0f);
                StrokeRoundedRect(
                    _Img, _B.m_fX, _B.m_fY, _B.m_fWidth, _B.m_fHeight, fr, 1.0f, _Border, 1.0f);
                return;
            }
            FillConvex(_Img, BoxShape(_B, _cShape), _Border, 1.0f);
            PixelBox inner{_B.m_fX + 1.0f, _B.m_fY + 1.0f, _B.m_fWidth - 2.0f, _B.m_fHeight - 2.0f};
            FillConvex(_Img, BoxShape(inner, _cShape), _Body, 1.0f);
            PixelBox head{inner.m_fX, inner.m_fY, fheadW, inner.m_fHeight};
            // The label end keeps the shape's left edge.
            std::vector<Point> headShape = BoxShape(inner, _cShape);
            for (Point& p : headShape)
            {
                p.m_fX = std::min(p.m_fX, head.m_fX + head.m_fWidth);
            }
            FillConvex(_Img, headShape, _Head, 1.0f);
        }

    } // namespace

    RevisionGraphPicture RenderRevisionGraph(
        const git::RevisionGraph& _Graph, const RevisionGraphStyle& _Style)
    {
        RevisionGraphPicture out;
        const int icolumns = std::max<int>(1, static_cast<int>(_Graph.m_Nodes.size()));
        int icolumn = _Style.m_iColumnWidth;
        const int imaxColumn =
            (ikMaxTexture - _Style.m_iMarginLeft - _Style.m_iMarginRight) / icolumns;
        icolumn = std::max(8, std::min(icolumn, imaxColumn));
        const float fscale =
            static_cast<float>(icolumn) / static_cast<float>(_Style.m_iColumnWidth);
        out.m_iColumnWidth = icolumn;

        const int irows = std::max<int>(1, static_cast<int>(_Graph.m_Rows.size()));
        const int iwidth = _Style.m_iMarginLeft + icolumns * icolumn + _Style.m_iMarginRight;
        const int iheight = std::min(ikMaxTexture, irows * _Style.m_iRowHeight + 1);
        out.m_Image = MakeImage(iwidth, iheight, FromHex(_Style.m_uiBackground), 1.0f);
        Image& img = out.m_Image;

        const float fnodeW = std::max(
            6.0f, std::min(static_cast<float>(_Style.m_iNodeWidth) * std::min(1.0f, fscale),
                      static_cast<float>(icolumn) - 3.0f));
        const float fnodeH = static_cast<float>(_Style.m_iNodeHeight);

        // Node boxes.
        for (const git::RevisionNode& node : _Graph.m_Nodes)
        {
            PixelBox box;
            box.m_fX = static_cast<float>(_Style.m_iMarginLeft + node.m_iColumn * icolumn);
            box.m_fY = static_cast<float>(node.m_iRow * _Style.m_iRowHeight + _Style.m_iNodeTop);
            box.m_fWidth = fnodeW;
            box.m_fHeight = fnodeH;
            out.m_Nodes.push_back(box);
        }

        // Row bands, separators, and lifetime bars.
        const int iselectedRow =
            _Style.m_iSelected >= 0 && _Style.m_iSelected < static_cast<int>(_Graph.m_Nodes.size())
                ? _Graph.m_Nodes[static_cast<std::size_t>(_Style.m_iSelected)].m_iRow
                : -1;
        for (int r = 0; r < static_cast<int>(_Graph.m_Rows.size()); ++r)
        {
            PixelBox row{0.0f, static_cast<float>(r * _Style.m_iRowHeight),
                static_cast<float>(iwidth), static_cast<float>(_Style.m_iRowHeight)};
            out.m_Rows.push_back(row);
            const std::uint32_t uiband = r == iselectedRow ? _Style.m_uiBandSelected
                                         : (r % 2 == 0)    ? _Style.m_uiBandA
                                                           : _Style.m_uiBandB;
            FillRoundedRect(
                img, row.m_fX, row.m_fY, row.m_fWidth, row.m_fHeight, 0.0f, FromHex(uiband), 1.0f);
            FillRoundedRect(img, 0.0f, row.m_fY + row.m_fHeight - 1.0f, row.m_fWidth, 1.0f, 0.0f,
                FromHex(_Style.m_uiRowLine), 1.0f);

            float ffirst = -1.0f;
            float flast = -1.0f;
            for (std::size_t n = 0; n < _Graph.m_Nodes.size(); ++n)
            {
                if (_Graph.m_Nodes[n].m_iRow != r)
                {
                    continue;
                }
                const PixelBox& b = out.m_Nodes[n];
                ffirst = ffirst < 0.0f ? b.m_fX : std::min(ffirst, b.m_fX);
                flast = std::max(flast, b.m_fX + b.m_fWidth);
            }
            if (ffirst >= 0.0f)
            {
                const float fbarY = row.m_fY + static_cast<float>(_Style.m_iNodeTop) + 3.0f;
                const float fbarH = fnodeH - 6.0f;
                const Colour bar = FromHex(_Style.m_uiBar);
                FillRoundedRect(img, ffirst, fbarY, flast - ffirst, fbarH, 0.0f, bar, 0.8f);
                FillGradientRect(img, flast, fbarY, static_cast<float>(iwidth) - flast - 4.0f,
                    fbarH, bar, 0.8f, bar, 0.0f);
            }
        }

        // Which revisions start a branch (first parent on another row).
        std::vector<bool> branched(_Graph.m_Nodes.size(), false);
        for (const git::RevisionEdge& edge : _Graph.m_Edges)
        {
            const auto& from = _Graph.m_Nodes[static_cast<std::size_t>(edge.m_iFrom)];
            const auto& to = _Graph.m_Nodes[static_cast<std::size_t>(edge.m_iTo)];
            if (!edge.m_bMerge && from.m_iRow != to.m_iRow)
            {
                branched[static_cast<std::size_t>(edge.m_iTo)] = true;
            }
        }

        // Boxes over the bars.
        const Colour body = FromHex(_Style.m_uiNode);
        const Colour head = FromHex(_Style.m_uiNodeHead);
        const Colour border = FromHex(_Style.m_uiNodeBorder);
        for (std::size_t n = 0; n < _Graph.m_Nodes.size(); ++n)
        {
            const git::RevisionNode& node = _Graph.m_Nodes[n];
            char cshape = 'M';
            if (node.m_cAction == 'A')
            {
                cshape = 'A';
            }
            else if (node.m_cAction == 'I')
            {
                cshape = 'I';
            }
            else if (branched[n])
            {
                cshape = 'B';
            }
            const bool bselected = static_cast<int>(n) == _Style.m_iSelected;
            const bool bdeleted = node.m_cAction == 'D';
            const Colour fill = bselected  ? FromHex(_Style.m_uiSelectedFill)
                                : bdeleted ? FromHex(_Style.m_uiDeleted)
                                           : body;
            const Colour label = bselected  ? FromHex(_Style.m_uiSelectedFill)
                                 : bdeleted ? FromHex(_Style.m_uiDeleted)
                                            : head;
            DrawBox(img, out.m_Nodes[n], cshape, fill, label,
                bselected ? FromHex(_Style.m_uiSelectedBorder) : border);
        }

        // Arrows last, over everything: merges black, branch points grey.
        for (const git::RevisionEdge& edge : _Graph.m_Edges)
        {
            const auto& from = _Graph.m_Nodes[static_cast<std::size_t>(edge.m_iFrom)];
            const auto& to = _Graph.m_Nodes[static_cast<std::size_t>(edge.m_iTo)];
            if (from.m_iRow == to.m_iRow && !edge.m_bMerge)
            {
                continue; // the row's bar already joins them
            }
            const PixelBox& a = out.m_Nodes[static_cast<std::size_t>(edge.m_iFrom)];
            const PixelBox& b = out.m_Nodes[static_cast<std::size_t>(edge.m_iTo)];
            const bool bdown = b.m_fY > a.m_fY;
            const Point start{a.m_fX + a.m_fWidth * 0.5f, bdown ? a.m_fY + a.m_fHeight : a.m_fY};
            const Point end{b.m_fX + 2.0f, b.m_fY + b.m_fHeight * 0.5f};
            DrawArrow(img, start, end,
                FromHex(edge.m_bMerge ? _Style.m_uiEdge : _Style.m_uiBranchEdge), 1.4f, 8.0f);
        }
        return out;
    }

} // namespace gitgud::imaging
