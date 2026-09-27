#pragma once

// -----------------------------------------------------------------------------
// GraphRenderer — draws commit-graph rows (git/CommitGraph.h) into RGBA
// pixels: anti-aliased lane lines, smooth curves where branches fork and
// merge, and a dot per commit. The Lua binding stacks many rows into one
// texture and hands each row out as its own image, so list rows can show
// their slice of the graph inline.
// -----------------------------------------------------------------------------

#include <cstdint>
#include <vector>

#include "git/CommitGraph.h"
#include "imaging/ImageDiff.h"

namespace gitgud::imaging
{

    // Per-row markers that change how the dot is drawn.
    enum GraphRowFlag : std::uint8_t
    {
        kGraphMerge = 1, // merge commit: a smaller dot
        kGraphHead = 2,  // HEAD: a halo ring around the dot
        kGraphWip = 4,   // the "uncommitted changes" row: a hollow dot, faint line
    };

    struct GraphStyle
    {
        int m_iLaneWidth = 16;
        int m_iRowHeight = 28;
        int m_iLanes = 8; // columns drawn; lanes further right are clipped
        int m_iPadding = 6;
        float m_fLineWidth = 2.0f;
        float m_fNodeRadius = 5.0f;
        std::vector<std::uint32_t> m_Colours = {0x7EF2D6}; // 0xRRGGBB, cycled by lane
        std::uint32_t m_uiBackground = 0x1F1738;           // gap around dots
        std::uint32_t m_uiHeadRing = 0xF3EEFC;
    };

    // Image width for a style (padding + lanes).
    int GraphWidth(const GraphStyle& _Style);

    // Draw rows [_nFirst, _nFirst + _nCount) stacked top to bottom into one
    // image of GraphWidth x (_nCount * row height). `_Flags` is indexed like
    // `_Rows` (missing entries mean 0).
    Image RenderGraphRows(const std::vector<git::GraphRow>& _Rows,
        const std::vector<std::uint8_t>& _Flags, std::size_t _nFirst, std::size_t _nCount,
        const GraphStyle& _Style);

} // namespace gitgud::imaging
