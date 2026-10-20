#include "ui/TextSpans.h"

#include <algorithm>
#include <cmath>

namespace gitgud::ui
{

    namespace
    {

        // Reads markup the way CEGUI's parser does and calls _Shown(nbyte,
        // piece) for each character shown, in order: piece is what it shows
        // (a [br] "\n", a picture or widget U+FFFC), nbyte where it starts
        // (0-based). Stops at byte _nEnd.
        template <typename Fn> void WalkShown(const std::string& _Markup, size_t _nEnd, Fn&& _Shown)
        {
            bool bescaped = false; // after a backslash
            bool bintag = false;   // inside [...]
            std::string tag;
            const size_t nend = std::min(_nEnd, _Markup.size());
            for (size_t nbyte = 0; nbyte < nend; ++nbyte)
            {
                const char c = _Markup[nbyte];
                // Continuation bytes (10xxxxxx) belong to the character before.
                if ((static_cast<unsigned char>(c) & 0xC0) == 0x80)
                {
                    continue;
                }
                size_t nlength = 1;
                while (nbyte + nlength < _Markup.size() &&
                       (static_cast<unsigned char>(_Markup[nbyte + nlength]) & 0xC0) == 0x80)
                {
                    ++nlength;
                }
                const std::string piece = _Markup.substr(nbyte, nlength);
                if (bintag)
                {
                    if (c == ']')
                    {
                        bintag = false;
                        // A line break, a picture or a widget takes one place.
                        if (tag == "br")
                        {
                            _Shown(nbyte, std::string("\n"));
                        }
                        else if (tag.rfind("image=", 0) == 0 || tag.rfind("window=", 0) == 0)
                        {
                            _Shown(nbyte, std::string("\xEF\xBF\xBC"));
                        }
                    }
                    else
                    {
                        tag.push_back(c);
                    }
                }
                else if (!bescaped && c == '[')
                {
                    bintag = true;
                    tag.clear();
                }
                else if (!bescaped && c == '\\')
                {
                    bescaped = true;
                }
                else
                {
                    // Only "\\" and "\[" are escapes: elsewhere the backslash shows.
                    if (bescaped && c != '\\' && c != '[')
                    {
                        _Shown(nbyte, std::string("\\"));
                    }
                    _Shown(nbyte, piece);
                    bescaped = false;
                }
            }
        }

    } // namespace

    std::vector<size_t> ShownIndices(const std::string& _Markup, size_t _nFirst, size_t _nLast)
    {
        std::vector<size_t> indices;
        if (_nFirst < 1 || _nLast < _nFirst)
        {
            return indices;
        }
        size_t nshown = 0; // characters shown so far
        WalkShown(_Markup, _nLast,
            [&](size_t _nByte, const std::string&)
            {
                if (_nByte + 1 >= _nFirst)
                {
                    indices.push_back(nshown);
                }
                ++nshown;
            });
        return indices;
    }

    std::string ShownText(const std::string& _Markup)
    {
        std::string out;
        WalkShown(
            _Markup, _Markup.size(), [&](size_t, const std::string& _Piece) { out += _Piece; });
        return out;
    }

    size_t ShownLength(const std::string& _Markup)
    {
        size_t nshown = 0;
        WalkShown(_Markup, _Markup.size(), [&](size_t, const std::string&) { ++nshown; });
        return nshown;
    }

    std::vector<PixelRect> JoinLineBoxes(const std::vector<PixelRect>& _Boxes)
    {
        std::vector<PixelRect> lines;
        for (const PixelRect& box : _Boxes)
        {
            if (box.m_fWidth <= 0.0f || box.m_fHeight <= 0.0f)
            {
                continue;
            }
            // Within half a line of the last one's top: the same line.
            if (!lines.empty() &&
                std::fabs(box.m_fY - lines.back().m_fY) < lines.back().m_fHeight * 0.5f)
            {
                PixelRect& line = lines.back();
                const float fleft = std::min(line.m_fX, box.m_fX);
                const float fright = std::max(line.m_fX + line.m_fWidth, box.m_fX + box.m_fWidth);
                const float ftop = std::min(line.m_fY, box.m_fY);
                const float fbottom =
                    std::max(line.m_fY + line.m_fHeight, box.m_fY + box.m_fHeight);
                line = PixelRect{fleft, ftop, fright - fleft, fbottom - ftop};
                continue;
            }
            lines.push_back(box);
        }
        return lines;
    }

} // namespace gitgud::ui
