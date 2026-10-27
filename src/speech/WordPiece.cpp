#include "speech/WordPiece.h"

#include <cstddef>

namespace gitgud::speech
{

    namespace
    {

        constexpr std::size_t kMaxWordChars = 100;

        std::vector<uint32_t> Decode(const std::string& _Text)
        {
            std::vector<uint32_t> out;
            for (std::size_t ni = 0; ni < _Text.size();)
            {
                const unsigned char c = static_cast<unsigned char>(_Text[ni]);
                std::size_t nlength = c < 0x80         ? 1
                                      : (c >> 5) == 6  ? 2
                                      : (c >> 4) == 14 ? 3
                                      : (c >> 3) == 30 ? 4
                                                       : 1;
                if (ni + nlength > _Text.size())
                {
                    nlength = 1;
                }
                uint32_t ucp = nlength == 1 ? c : c & (0xFF >> (nlength + 1));
                for (std::size_t nk = 1; nk < nlength; ++nk)
                {
                    ucp = (ucp << 6) | (static_cast<unsigned char>(_Text[ni + nk]) & 0x3F);
                }
                out.push_back(nlength == 1 && c >= 0x80 ? 0xFFFD : ucp);
                ni += nlength;
            }
            return out;
        }

        void Append(std::string& _Out, uint32_t _uCp)
        {
            if (_uCp < 0x80)
            {
                _Out += static_cast<char>(_uCp);
            }
            else if (_uCp < 0x800)
            {
                _Out += static_cast<char>(0xC0 | (_uCp >> 6));
                _Out += static_cast<char>(0x80 | (_uCp & 0x3F));
            }
            else if (_uCp < 0x10000)
            {
                _Out += static_cast<char>(0xE0 | (_uCp >> 12));
                _Out += static_cast<char>(0x80 | ((_uCp >> 6) & 0x3F));
                _Out += static_cast<char>(0x80 | (_uCp & 0x3F));
            }
            else
            {
                _Out += static_cast<char>(0xF0 | (_uCp >> 18));
                _Out += static_cast<char>(0x80 | ((_uCp >> 12) & 0x3F));
                _Out += static_cast<char>(0x80 | ((_uCp >> 6) & 0x3F));
                _Out += static_cast<char>(0x80 | (_uCp & 0x3F));
            }
        }

        bool IsSpace(uint32_t _uCp)
        {
            return _uCp == ' ' || _uCp == '\t' || _uCp == '\n' || _uCp == '\r' || _uCp == 0xA0 ||
                   _uCp == 0x1680 || (_uCp >= 0x2000 && _uCp <= 0x200A) || _uCp == 0x202F ||
                   _uCp == 0x205F || _uCp == 0x3000;
        }

        // Control and format characters (dropped), and what can't be read.
        bool IsControl(uint32_t _uCp)
        {
            return _uCp == 0 || _uCp == 0xFFFD || (_uCp < 0x20 && !IsSpace(_uCp)) ||
                   (_uCp >= 0x7F && _uCp <= 0x9F) || _uCp == 0xAD ||
                   (_uCp >= 0x200B && _uCp <= 0x200F) || (_uCp >= 0x202A && _uCp <= 0x202E) ||
                   (_uCp >= 0x2060 && _uCp <= 0x2064) || _uCp == 0xFEFF;
        }

        // Every ASCII symbol counts, as in BERT; elsewhere, Unicode's
        // punctuation in the common blocks.
        bool IsPunctuation(uint32_t _uCp)
        {
            if (_uCp < 0x80)
            {
                return (_uCp >= 33 && _uCp <= 47) || (_uCp >= 58 && _uCp <= 64) ||
                       (_uCp >= 91 && _uCp <= 96) || (_uCp >= 123 && _uCp <= 126);
            }
            return _uCp == 0xA1 || _uCp == 0xA7 || _uCp == 0xAB || _uCp == 0xB6 || _uCp == 0xB7 ||
                   _uCp == 0xBB || _uCp == 0xBF || (_uCp >= 0x2010 && _uCp <= 0x2027) ||
                   (_uCp >= 0x2030 && _uCp <= 0x2043) || (_uCp >= 0x2045 && _uCp <= 0x2051) ||
                   (_uCp >= 0x2053 && _uCp <= 0x205E) || (_uCp >= 0x3001 && _uCp <= 0x3003) ||
                   (_uCp >= 0x3008 && _uCp <= 0x3011) || (_uCp >= 0x3014 && _uCp <= 0x301F) ||
                   (_uCp >= 0xFF01 && _uCp <= 0xFF03) || (_uCp >= 0xFF05 && _uCp <= 0xFF0A) ||
                   (_uCp >= 0xFF0C && _uCp <= 0xFF0F) || _uCp == 0xFF1A || _uCp == 0xFF1B ||
                   _uCp == 0xFF1F || _uCp == 0xFF20 || (_uCp >= 0xFF3B && _uCp <= 0xFF3D) ||
                   _uCp == 0xFF3F || _uCp == 0xFF5B || _uCp == 0xFF5D;
        }

        bool IsCjk(uint32_t _uCp)
        {
            return (_uCp >= 0x4E00 && _uCp <= 0x9FFF) || (_uCp >= 0x3400 && _uCp <= 0x4DBF) ||
                   (_uCp >= 0x20000 && _uCp <= 0x2A6DF) || (_uCp >= 0x2A700 && _uCp <= 0x2CEAF) ||
                   (_uCp >= 0xF900 && _uCp <= 0xFAFF) || (_uCp >= 0x2F800 && _uCp <= 0x2FA1F);
        }

        // U+00C0 to U+017F without their accents, lowercase: the base
        // letter, or '.' for a letter with no accent to take off (kept, and
        // lowercased by kLower).
        constexpr const char* kLatin1 = "aaaaaa.ceeeeiiii.nooooo..uuuuy.."
                                        "aaaaaa.ceeeeiiii.nooooo..uuuuy.y";
        constexpr const char* kExtendedA =
            "aaaaaaccccccccdd..eeeeeeeeeegggggggghh..iiiiiiiii...jjkk."
            "llllll....nnnnnn...oooooo..rrrrrrsssssssstttt..uuuuuuuuuuuu"
            "wwyyyzzzzzz.";

        uint32_t LowerKept(uint32_t _uCp)
        {
            switch (_uCp)
            {
            case 0xC6: // Æ
            case 0xD0: // Ð
            case 0xD8: // Ø
            case 0xDE: // Þ
                return _uCp + 0x20;
            case 0x110: // Đ
            case 0x126: // Ħ
            case 0x132: // Ĳ
            case 0x13F: // Ŀ
            case 0x141: // Ł
            case 0x14A: // Ŋ
            case 0x152: // Œ
            case 0x166: // Ŧ
                return _uCp + 1;
            default:
                return _uCp;
            }
        }

        // Lowercase, accents off (several code points for none).
        uint32_t Fold(uint32_t _uCp)
        {
            if (_uCp >= 'A' && _uCp <= 'Z')
            {
                return _uCp + 32;
            }
            if (_uCp >= 0xC0 && _uCp <= 0xFF)
            {
                const char c = kLatin1[_uCp - 0xC0];
                return c == '.' ? LowerKept(_uCp) : static_cast<uint32_t>(c);
            }
            if (_uCp >= 0x100 && _uCp <= 0x17F)
            {
                const char c = kExtendedA[_uCp - 0x100];
                return c == '.' ? LowerKept(_uCp) : static_cast<uint32_t>(c);
            }
            // Combining accents on their own go, as accents do.
            if (_uCp >= 0x300 && _uCp <= 0x36F)
            {
                return 0;
            }
            return _uCp;
        }

    } // namespace

    bool WordPiece::Load(const std::string& _Text, std::string& _Error)
    {
        m_Vocab.clear();
        int64_t iid = 0;
        std::size_t nstart = 0;
        while (nstart < _Text.size())
        {
            std::size_t nend = _Text.find('\n', nstart);
            if (nend == std::string::npos)
            {
                nend = _Text.size();
            }
            std::string piece = _Text.substr(nstart, nend - nstart);
            if (!piece.empty() && piece.back() == '\r')
            {
                piece.pop_back();
            }
            m_Vocab.emplace(piece, iid++);
            nstart = nend + 1;
        }
        auto find = [&](const char* _szPiece)
        {
            const auto it = m_Vocab.find(_szPiece);
            return it == m_Vocab.end() ? int64_t{-1} : it->second;
        };
        m_iCls = find("[CLS]");
        m_iSep = find("[SEP]");
        m_iUnk = find("[UNK]");
        if (m_iCls < 0 || m_iSep < 0 || m_iUnk < 0)
        {
            m_Vocab.clear();
            _Error = "not a WordPiece vocabulary (no [CLS], [SEP], or [UNK])";
            return false;
        }
        return true;
    }

    std::vector<std::string> WordPiece::Words(const std::string& _Text)
    {
        std::vector<std::string> words;
        std::string word;
        auto flush = [&]()
        {
            if (!word.empty())
            {
                words.push_back(word);
                word.clear();
            }
        };
        for (const uint32_t ucp : Decode(_Text))
        {
            if (IsControl(ucp))
            {
                continue;
            }
            if (IsSpace(ucp))
            {
                flush();
                continue;
            }
            const uint32_t ufolded = Fold(ucp);
            if (ufolded == 0)
            {
                continue;
            }
            if (IsPunctuation(ufolded) || IsCjk(ufolded))
            {
                flush();
                Append(word, ufolded);
                flush();
                continue;
            }
            Append(word, ufolded);
        }
        flush();
        return words;
    }

    std::vector<int64_t> WordPiece::Encode(const std::string& _Text) const
    {
        std::vector<int64_t> ids;
        for (const std::string& word : Words(_Text))
        {
            if (Decode(word).size() > kMaxWordChars)
            {
                ids.push_back(m_iUnk);
                continue;
            }
            std::vector<int64_t> pieces;
            std::size_t nstart = 0;
            bool bok = true;
            while (nstart < word.size())
            {
                // The longest piece from here (cut only between characters).
                std::size_t nend = word.size();
                int64_t ifound = -1;
                while (nend > nstart)
                {
                    const std::string piece =
                        (nstart > 0 ? "##" : "") + word.substr(nstart, nend - nstart);
                    const auto it = m_Vocab.find(piece);
                    if (it != m_Vocab.end())
                    {
                        ifound = it->second;
                        break;
                    }
                    do
                    {
                        --nend;
                    } while (
                        nend > nstart && (static_cast<unsigned char>(word[nend]) & 0xC0) == 0x80);
                }
                if (ifound < 0)
                {
                    bok = false;
                    break;
                }
                pieces.push_back(ifound);
                nstart = nend;
            }
            if (bok)
            {
                ids.insert(ids.end(), pieces.begin(), pieces.end());
            }
            else
            {
                ids.push_back(m_iUnk);
            }
        }
        return ids;
    }

} // namespace gitgud::speech
