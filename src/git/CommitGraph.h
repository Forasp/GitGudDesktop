#pragma once

// -----------------------------------------------------------------------------
// CommitGraph — lane layout for drawing history as a graph.
//
// Pure data in, pure data out: no libgit2 and no pixels. Repository::GraphLog
// supplies commits (newest first, every commit above its parents); this file
// assigns each one a lane (column) and describes the line segments every row
// needs, and src/imaging/GraphRenderer.cpp turns rows into pictures.
//
// A row is drawn in two halves. The TOP half runs from the row's top edge to
// its middle, where the commit's dot sits; the BOTTOM half runs from the
// middle to the bottom edge. Every edge says which lane it starts in and
// which lane it ends in (equal for a straight line, different for a curve
// where branches fork or merge).
//
// Lanes are stable: a branch keeps its column until it ends, and freed
// columns are reused, so long-lived branches stay put as you scroll.
// -----------------------------------------------------------------------------

#include <string>
#include <vector>

namespace gitgud::git
{

    // One commit as the layout sees it.
    struct GraphNode
    {
        std::string m_Oid;
        std::vector<std::string> m_Parents; // first parent first
    };

    struct GraphEdge
    {
        int m_iFrom = 0;    // lane at the start of the segment
        int m_iTo = 0;      // lane at the end of the segment
        int m_iColour = 0;  // palette index (lanes keep their colour)
        bool m_bTop = true; // top half (row top -> dot) or bottom half (dot -> row bottom)
    };

    struct GraphRow
    {
        int m_iLane = 0;      // column of this commit's dot
        int m_iColour = 0;    // palette index of the dot
        int m_iLaneCount = 0; // columns this row touches (for sizing)
        std::vector<GraphEdge> m_Edges;
    };

    // Lay out `_Nodes` (in display order, newest first; every commit must come
    // before its parents, as a topological revwalk guarantees). Parents that
    // aren't in `_Nodes` (paging) simply run off the bottom of the graph.
    std::vector<GraphRow> LayoutGraph(const std::vector<GraphNode>& _Nodes);

} // namespace gitgud::git
