#pragma once

// -----------------------------------------------------------------------------
// RevisionGraphRenderer — draws a git::RevisionGraph as a
// revision graph: a band per branch row, a box per revision (its shape says
// what happened: added, edited, deleted, merged in, branched), a fading bar
// for the row's lifetime, and arrows for merges and branch points.
//
// Text isn't drawn here: the picture comes back with every box's and row's
// position so the UI can lay its own labels (revision numbers, branch names,
// commit ids) over it — and hit-test clicks.
// -----------------------------------------------------------------------------

#include <cstdint>
#include <vector>

#include "git/Repository.h"
#include "imaging/ImageDiff.h"

namespace gitgud::imaging
{

    struct RevisionGraphStyle
    {
        int m_iColumnWidth = 56; // horizontal step per revision
        int m_iRowHeight = 64;
        int m_iNodeWidth = 44;
        int m_iNodeHeight = 26;
        int m_iNodeTop = 10; // node offset from its row's top
        int m_iMarginLeft = 12;
        int m_iMarginRight = 120; // room for the last row bar to fade out
        int m_iSelected = -1;     // node index drawn highlighted
        // 0xRRGGBB colours (a light scheme by default).
        std::uint32_t m_uiBackground = 0xFFFFFF;
        std::uint32_t m_uiBandA = 0xFFFFFF;
        std::uint32_t m_uiBandB = 0xF5F5F5;
        std::uint32_t m_uiBandSelected = 0xE3E3E3;
        std::uint32_t m_uiRowLine = 0xD4D4D4;
        std::uint32_t m_uiNode = 0xD9D9F7;     // box body
        std::uint32_t m_uiNodeHead = 0x9D9DE6; // box's darker label end
        std::uint32_t m_uiNodeBorder = 0x7373C9;
        std::uint32_t m_uiDeleted = 0xB8B8B8;
        std::uint32_t m_uiBar = 0xC9C9F2; // row lifetime bar
        std::uint32_t m_uiEdge = 0x101010;
        std::uint32_t m_uiBranchEdge = 0x505050;
        std::uint32_t m_uiSelectedFill = 0xFFF36B;
        std::uint32_t m_uiSelectedBorder = 0xE03A3A;
    };

    struct PixelBox
    {
        float m_fX = 0.0f;
        float m_fY = 0.0f;
        float m_fWidth = 0.0f;
        float m_fHeight = 0.0f;
    };

    struct RevisionGraphPicture
    {
        Image m_Image;
        std::vector<PixelBox> m_Nodes; // parallel to graph.m_Nodes
        std::vector<PixelBox> m_Rows;  // parallel to graph.m_Rows
        int m_iColumnWidth = 0;        // after clamping to the texture limit
    };

    RevisionGraphPicture RenderRevisionGraph(
        const git::RevisionGraph& _Graph, const RevisionGraphStyle& _Style);

} // namespace gitgud::imaging
