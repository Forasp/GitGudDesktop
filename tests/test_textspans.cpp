// Tests for finding a run of a widget's text: byte offsets into its markup
// to the indices of the characters shown, and the characters' boxes joined
// into one rectangle per line.

#include <catch2/catch_test_macros.hpp>

#include "ui/TextSpans.h"

#include <string>
#include <vector>

using namespace gitgud::ui;

TEST_CASE("markup tags show nothing", "[textspans]")
{
    const std::string markup = "ab[colour='FF000000']cd";
    // "cd" is bytes 22 and 23, shown third and fourth.
    CHECK(ShownIndices(markup, 22, 23) == std::vector<size_t>{2, 3});
    CHECK(ShownIndices(markup, 1, 1) == std::vector<size_t>{0});
    // The tag itself: nothing.
    CHECK(ShownIndices(markup, 3, 21).empty());

    // Past the end, backwards, or from 0: nothing.
    CHECK(ShownIndices(markup, 30, 40).empty());
    CHECK(ShownIndices(markup, 5, 4).empty());
    CHECK(ShownIndices(markup, 0, 3).empty());
}

TEST_CASE("line breaks and pictures take one place", "[textspans]")
{
    const std::string markup = "a[br]b[image='Set/Name']c[image-size='w:16 h:16']d";
    // a 0, [br] 1, b 2, [image] 3, c 4, d 5.
    const size_t nd = markup.size();
    CHECK(ShownIndices(markup, nd, nd) == std::vector<size_t>{5});
    CHECK(ShownIndices(markup, 2, 6) == std::vector<size_t>{1, 2});
}

TEST_CASE("escapes: only \\[ and \\\\", "[textspans]")
{
    // "\[x" shows "[x"; "D:\P" shows the backslash too.
    const std::string markup = "\\[x D:\\P";
    // \ 1, [ 2, x 3, ' ' 4, D 5, : 6, \ 7, P 8.
    CHECK(ShownIndices(markup, 2, 3) == std::vector<size_t>{0, 1});
    // The backslash of "\P" shows with the P.
    CHECK(ShownIndices(markup, 5, 8) == std::vector<size_t>{3, 4, 5, 6});
    CHECK(ShownIndices("a\\\\b", 1, 4) == std::vector<size_t>{0, 1, 2});
}

TEST_CASE("multi-byte characters count once", "[textspans]")
{
    // "\u00e9" is two bytes, "\u2192" three.
    const std::string markup = "\xC3\xA9 x \xE2\x86\x92 y";
    // Bytes: e-acute 1-2, ' ' 3, 'x' 4, ' ' 5, arrow 6-8, ' ' 9, 'y' 10.
    CHECK(ShownIndices(markup, 4, 4) == std::vector<size_t>{2});
    CHECK(ShownIndices(markup, 6, 10) == std::vector<size_t>{4, 5, 6});
    // A range starting inside a character leaves that one out.
    CHECK(ShownIndices(markup, 2, 4) == std::vector<size_t>{1, 2});
}

TEST_CASE("boxes join into one rectangle per line", "[textspans]")
{
    const std::vector<PixelRect> boxes = {
        {100, 20, 8, 18},
        {108, 20, 8, 18},
        {116, 21, 0, 18}, // empty: skipped
        {116, 20, 9, 18},
        {0, 40, 8, 18}, // wrapped onto the next line
        {8, 40, 7, 18},
    };
    const std::vector<PixelRect> lines = JoinLineBoxes(boxes);
    REQUIRE(lines.size() == 2);
    CHECK(lines[0].m_fX == 100);
    CHECK(lines[0].m_fY == 20);
    CHECK(lines[0].m_fWidth == 25);
    CHECK(lines[0].m_fHeight == 18);
    CHECK(lines[1].m_fX == 0);
    CHECK(lines[1].m_fY == 40);
    CHECK(lines[1].m_fWidth == 15);

    CHECK(JoinLineBoxes({}).empty());
}

TEST_CASE("shown text: what markup shows, for copying", "[textspans]")
{
    CHECK(ShownText("ab[colour='FF000000']cd") == "abcd");
    CHECK(ShownText("a[br]b") == "a\nb");
    CHECK(ShownText("a[image='Set/Name']b") == std::string("a\xEF\xBF\xBC") + "b");
    CHECK(ShownText("[font='Bragi-14']x[image-size='w:16 h:16']y") == "xy");
    // Escapes: "\[" shows "[", "\\" one backslash; any other backslash shows.
    CHECK(ShownText("\\[x] C:\\Work") == "[x] C:\\Work");
    CHECK(ShownText("a\\\\b") == "a\\b");
    CHECK(ShownText("\xC3\xA9 \xE2\x86\x92") == "\xC3\xA9 \xE2\x86\x92");
    CHECK(ShownText("") == "");
}

TEST_CASE("shown length counts what shows, and matches the indices", "[textspans]")
{
    CHECK(ShownLength("ab[colour='FF000000']cd") == 4);
    CHECK(ShownLength("a[br]b[image='S/N']") == 4);
    CHECK(ShownLength("D:\\P") == 4);
    CHECK(ShownLength("\xC3\xA9 \xE2\x86\x92") == 3);
    // The last shown character's index is one less than the length.
    const std::string markup = "x\\[y[colour='FF000000']\xE2\x86\x92 D:\\Q";
    const std::vector<size_t> all = ShownIndices(markup, 1, markup.size());
    REQUIRE(!all.empty());
    CHECK(all.back() + 1 == ShownLength(markup));
}
