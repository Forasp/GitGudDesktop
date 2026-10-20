#pragma once

// -----------------------------------------------------------------------------
// TextSpans: where a run of a widget's text sits on screen, for the scripts
// to lay clickable links over it (gitgud.textRects), and what it shows, for
// selecting and copying it (gitgud.shownText, textIndexAt, shownRects).
//
// The scripts name a run by byte offsets into the UTF-8 markup they set;
// the renderer counts the characters it shows (markup tags left out) and
// measures one at a time. These turn the one into the other and join the
// characters' boxes into one rectangle per line the run wraps onto.
// -----------------------------------------------------------------------------

#include "ui/IUiBackend.h"

#include <cstddef>
#include <string>
#include <vector>

namespace gitgud::ui
{

    // Where the characters that start at bytes _nFirst to _nLast (1-based,
    // inclusive) of the UTF-8 _Markup are in the text it shows (0-based,
    // counting code points), read the way CEGUI's markup parser reads it:
    // [tags] show nothing ([br], [image=...] and [window=...] one
    // character), "\[" and "\\" show the second character, and any other
    // backslash shows. Empty when the range is empty, outside the text, or
    // only markup.
    std::vector<size_t> ShownIndices(const std::string& _Markup, size_t _nFirst, size_t _nLast);

    // The text markup shows, as UTF-8: tags left out, a [br] as "\n", a
    // picture or a widget as U+FFFC, escapes read. Its Nth code point is
    // the character CEGUI shows at index N.
    std::string ShownText(const std::string& _Markup);

    // How many characters markup shows (code points of ShownText).
    size_t ShownLength(const std::string& _Markup);

    // Characters' boxes, in text order, joined into one rectangle per line:
    // a box on the line of the one before widens that rectangle, a box
    // lower down starts the next. Empty boxes are skipped.
    std::vector<PixelRect> JoinLineBoxes(const std::vector<PixelRect>& _Boxes);

} // namespace gitgud::ui
