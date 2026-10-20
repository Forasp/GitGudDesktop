#pragma once

// -----------------------------------------------------------------------------
// ColourMap: a UI package's colours for the GitGud UI's files and its own.
//
// A colour file (a package's colours.ini, or one of its themes/<name>.ini)
// holds two kinds of line:
//
//     # Synthwave canvas -> teal: recolours the GitGud UI's own files, which
//     # spell their colours out as CEGUI AARRGGBB hex
//     FF17102B = FF123C38
//
//     # A named token: the package's own layouts and scripts write $panel
//     panel = FF213330
//
// Every layout and looknfeel file, and the text and properties scripts set,
// go through the map as they load (CeguiBackend), so the GitGud UI's files
// take the package's palette unchanged and one package layout serves every
// theme. Blank lines and lines starting with '#' or ';' are ignored, as are
// malformed ones; a value may be followed by a "# note". Token names are letters, digits, '-' and '_', starting
// with a letter.
// -----------------------------------------------------------------------------

#include <string>
#include <unordered_map>

namespace gitgud::ui
{

    // Upper-case AARRGGBB -> replacement, and "$name" -> AARRGGBB for named
    // tokens, as written in the file.
    using ColourMap = std::unordered_map<std::string, std::string>;

    // Parse colour file text.
    ColourMap ParseColourMap(const std::string& _Text);

    // Read and parse a colour file; an empty map if _Path is "" or unreadable.
    ColourMap LoadColourFile(const std::string& _Path);

    // Swap every 8-hex-digit token in _Text (one not touching another letter
    // or digit) that the map names, matching case-insensitively, and every
    // $name the map defines. Unknown $names stay as written.
    std::string Recolour(const std::string& _Text, const ColourMap& _Map);

    // The same, but only inside CEGUI markup tags ("[colour='$accent']"; a
    // tag starts at a '[' not escaped with a backslash). For display text,
    // where a "$name" or hex word in the content itself must stay as is.
    std::string RecolourMarkup(const std::string& _Text, const ColourMap& _Map);

    // A named token's colour ("accent" -> "FFE8B866"), or "" when the map
    // doesn't define it.
    std::string TokenColour(const ColourMap& _Map, const std::string& _Name);

} // namespace gitgud::ui
