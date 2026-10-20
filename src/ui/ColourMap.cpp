#include "ui/ColourMap.h"

#include <cctype>
#include <filesystem>
#include <fstream>
#include <sstream>

namespace gitgud::ui
{

    namespace
    {

        bool IsHex(char _C)
        {
            return std::isxdigit(static_cast<unsigned char>(_C)) != 0;
        }

        bool IsWordChar(char _C)
        {
            return std::isalnum(static_cast<unsigned char>(_C)) != 0 || _C == '_';
        }

        std::string Trim(const std::string& _S)
        {
            const auto nfirst = _S.find_first_not_of(" \t\r\n");
            if (nfirst == std::string::npos)
            {
                return {};
            }
            const auto nlast = _S.find_last_not_of(" \t\r\n");
            return _S.substr(nfirst, nlast - nfirst + 1);
        }

        // An 8-digit AARRGGBB colour, upper-cased; "" if _S isn't one.
        std::string Colour(const std::string& _S)
        {
            if (_S.size() != 8)
            {
                return {};
            }
            std::string upper = _S;
            for (char& c : upper)
            {
                if (!IsHex(c))
                {
                    return {};
                }
                c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
            }
            return upper;
        }

        bool IsNameStart(char _C)
        {
            return std::isalpha(static_cast<unsigned char>(_C)) != 0;
        }

        bool IsNameChar(char _C)
        {
            return std::isalnum(static_cast<unsigned char>(_C)) != 0 || _C == '-' || _C == '_';
        }

        // A token name: a letter, then letters, digits, '-' or '_'.
        bool IsName(const std::string& _S)
        {
            if (_S.empty() || !IsNameStart(_S[0]))
            {
                return false;
            }
            for (char c : _S)
            {
                if (!IsNameChar(c))
                {
                    return false;
                }
            }
            return true;
        }

    } // namespace

    ColourMap ParseColourMap(const std::string& _Text)
    {
        ColourMap map;
        std::istringstream in(_Text);
        std::string line;
        while (std::getline(in, line))
        {
            line = Trim(line);
            if (line.empty() || line[0] == '#' || line[0] == ';')
            {
                continue;
            }
            const auto neq = line.find('=');
            if (neq == std::string::npos)
            {
                continue;
            }
            const std::string key = Trim(line.substr(0, neq));
            std::string value = line.substr(neq + 1);
            if (const auto ncomment = value.find('#'); ncomment != std::string::npos)
            {
                value.erase(ncomment); // a trailing "# note"
            }
            const std::string to = Colour(Trim(value));
            if (to.empty())
            {
                continue;
            }
            const std::string from = Colour(key);
            if (!from.empty())
            {
                map[from] = to;
            }
            else if (IsName(key))
            {
                map["$" + key] = to;
            }
        }
        return map;
    }

    ColourMap LoadColourFile(const std::string& _Path)
    {
        if (_Path.empty())
        {
            return {};
        }
        std::ifstream in(std::filesystem::u8path(_Path), std::ios::binary);
        if (!in)
        {
            return {};
        }
        std::ostringstream text;
        text << in.rdbuf();
        return ParseColourMap(text.str());
    }

    namespace
    {

        // Recolour every token in [_nBegin, _nEnd) of _Text onto _Out.
        void RecolourSpan(const std::string& _Text, size_t _nBegin, size_t _nEnd,
            const ColourMap& _Map, std::string& _Out)
        {
            size_t i = _nBegin;
            while (i < _nEnd)
            {
                if (_Text[i] == '$' && i + 1 < _nEnd && IsNameStart(_Text[i + 1]))
                {
                    size_t nend = i + 1;
                    while (nend < _nEnd && IsNameChar(_Text[nend]))
                    {
                        ++nend;
                    }
                    const auto it = _Map.find(_Text.substr(i, nend - i));
                    _Out += it == _Map.end() ? _Text.substr(i, nend - i) : it->second;
                    i = nend;
                    continue;
                }
                // A run of word characters is one token: recolour it only when
                // the whole run is a colour, so "FF17102B0" or "xFF17102B" stay.
                if (!IsWordChar(_Text[i]))
                {
                    _Out += _Text[i++];
                    continue;
                }
                size_t nend = i;
                while (nend < _nEnd && IsWordChar(_Text[nend]))
                {
                    ++nend;
                }
                const std::string token = _Text.substr(i, nend - i);
                const std::string colour = Colour(token);
                const auto it = colour.empty() ? _Map.end() : _Map.find(colour);
                _Out += it == _Map.end() ? token : it->second;
                i = nend;
            }
        }

    } // namespace

    std::string Recolour(const std::string& _Text, const ColourMap& _Map)
    {
        if (_Map.empty())
        {
            return _Text;
        }
        std::string out;
        out.reserve(_Text.size());
        RecolourSpan(_Text, 0, _Text.size(), _Map, out);
        return out;
    }

    std::string RecolourMarkup(const std::string& _Text, const ColourMap& _Map)
    {
        if (_Map.empty() || _Text.find('[') == std::string::npos)
        {
            return _Text;
        }
        std::string out;
        out.reserve(_Text.size());
        size_t i = 0;
        while (i < _Text.size())
        {
            // A markup tag: '[' not escaped with a backslash, up to its ']'.
            const bool btag = _Text[i] == '[' && (i == 0 || _Text[i - 1] != '\\');
            const size_t nclose = btag ? _Text.find(']', i) : std::string::npos;
            if (nclose == std::string::npos)
            {
                out += _Text[i++];
                continue;
            }
            RecolourSpan(_Text, i, nclose + 1, _Map, out);
            i = nclose + 1;
        }
        return out;
    }

    std::string TokenColour(const ColourMap& _Map, const std::string& _Name)
    {
        const auto it = _Map.find("$" + _Name);
        return it == _Map.end() ? std::string() : it->second;
    }

} // namespace gitgud::ui
