#include "speech/Gpt2Tokenizer.h"

#include "app/Json.h"

#include <climits>

namespace gitgud::speech
{

    using app::Json;

    namespace
    {

        // One UTF-8 character: its code point and byte length.
        struct Char
        {
            uint32_t m_uCp = 0;
            std::size_t m_nBegin = 0;
            std::size_t m_nLength = 1;
        };

        std::vector<Char> Decode(const std::string& _Text)
        {
            std::vector<Char> out;
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
                out.push_back({ucp, ni, nlength});
                ni += nlength;
            }
            return out;
        }

        bool IsSpace(uint32_t _uCp)
        {
            return _uCp == ' ' || (_uCp >= 0x09 && _uCp <= 0x0D) ||
                   (_uCp >= 0x1C && _uCp <= 0x1F) || _uCp == 0x85 || _uCp == 0xA0 ||
                   _uCp == 0x1680 || (_uCp >= 0x2000 && _uCp <= 0x200A) || _uCp == 0x2028 ||
                   _uCp == 0x2029 || _uCp == 0x202F || _uCp == 0x205F || _uCp == 0x3000;
        }

        bool IsDigit(uint32_t _uCp)
        {
            return _uCp >= '0' && _uCp <= '9';
        }

        // Letters: ASCII ones, and anything beyond ASCII that isn't a space or
        // general punctuation (close enough to Unicode's letters for English).
        bool IsLetter(uint32_t _uCp)
        {
            if (_uCp < 0x80)
            {
                return (_uCp >= 'a' && _uCp <= 'z') || (_uCp >= 'A' && _uCp <= 'Z');
            }
            if (IsSpace(_uCp) || (_uCp >= 0x2010 && _uCp <= 0x205E) ||
                (_uCp >= 0xA1 && _uCp <= 0xBF) || _uCp == 0xD7 || _uCp == 0xF7)
            {
                return false;
            }
            return true;
        }

        bool IsOther(uint32_t _uCp)
        {
            return !IsSpace(_uCp) && !IsDigit(_uCp) && !IsLetter(_uCp) && _uCp != '_';
        }

    } // namespace

    std::vector<std::string> Gpt2Tokenizer::PreSplit(const std::string& _Text)
    {
        // GPT-2's pattern, in order:
        // 's|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\d+| ?[^\s\w]+|\s+(?!\S)|\s+|_+
        const std::vector<Char> chars = Decode(_Text);
        const std::size_t ncount = chars.size();
        std::vector<std::string> out;
        auto emit = [&](std::size_t _nFrom, std::size_t _nTo)
        {
            const std::size_t nbegin = chars[_nFrom].m_nBegin;
            const std::size_t nend = _nTo < ncount ? chars[_nTo].m_nBegin : _Text.size();
            out.push_back(_Text.substr(nbegin, nend - nbegin));
        };
        auto run = [&](std::size_t _nFrom, bool (*_pClass)(uint32_t))
        {
            std::size_t nj = _nFrom;
            while (nj < ncount && _pClass(chars[nj].m_uCp))
            {
                ++nj;
            }
            return nj;
        };
        std::size_t ni = 0;
        while (ni < ncount)
        {
            const uint32_t c = chars[ni].m_uCp;
            const uint32_t next = ni + 1 < ncount ? chars[ni + 1].m_uCp : 0;
            const uint32_t next2 = ni + 2 < ncount ? chars[ni + 2].m_uCp : 0;
            if (c == '\'')
            {
                if (next == 's' || next == 't' || next == 'm' || next == 'd')
                {
                    emit(ni, ni + 2);
                    ni += 2;
                    continue;
                }
                if ((next == 'r' && next2 == 'e') || (next == 'v' && next2 == 'e') ||
                    (next == 'l' && next2 == 'l'))
                {
                    emit(ni, ni + 3);
                    ni += 3;
                    continue;
                }
            }
            const bool bspace = c == ' ' && ni + 1 < ncount;
            bool (*const classes[])(uint32_t) = {IsLetter, IsDigit, IsOther};
            bool bdone = false;
            for (auto pclass : classes)
            {
                if (bspace && pclass(next))
                {
                    const std::size_t nj = run(ni + 1, pclass);
                    emit(ni, nj);
                    ni = nj;
                    bdone = true;
                    break;
                }
                if (pclass(c))
                {
                    const std::size_t nj = run(ni, pclass);
                    emit(ni, nj);
                    ni = nj;
                    bdone = true;
                    break;
                }
            }
            if (bdone)
            {
                continue;
            }
            if (IsSpace(c))
            {
                const std::size_t nj = run(ni, IsSpace);
                // \s+(?!\S): the run, less its last space when text follows.
                if (nj == ncount || nj - ni == 1)
                {
                    emit(ni, nj);
                    ni = nj;
                }
                else
                {
                    emit(ni, nj - 1);
                    ni = nj - 1;
                }
                continue;
            }
            if (c == '_')
            {
                std::size_t nj = ni;
                while (nj < ncount && chars[nj].m_uCp == '_')
                {
                    ++nj;
                }
                emit(ni, nj);
                ni = nj;
                continue;
            }
            emit(ni, ni + 1);
            ++ni;
        }
        return out;
    }

    bool Gpt2Tokenizer::Load(const std::string& _Json, std::string& _Error)
    {
        const std::optional<Json> parsed = Json::Parse(_Json, &_Error);
        if (!parsed || !parsed->IsObject() || !(*parsed)["model"]["vocab"].IsObject())
        {
            _Error = _Error.empty() ? "not a tokenizer.json" : _Error;
            return false;
        }
        const Json& model = (*parsed)["model"];
        m_Vocab.clear();
        m_Ranks.clear();
        m_Special.clear();
        const Json& vocab = model["vocab"];
        const std::vector<std::string>& keys = vocab.Keys();
        for (std::size_t ni = 0; ni < keys.size(); ++ni)
        {
            m_Vocab[keys[ni]] = vocab[keys[ni]].AsInt(-1);
        }
        int irank = 0;
        for (const Json& merge : model["merges"].Items())
        {
            std::string a;
            std::string b;
            if (merge.IsString())
            {
                const std::string& text = merge.AsString();
                const std::size_t nspace = text.find(' ');
                if (nspace == std::string::npos)
                {
                    continue;
                }
                a = text.substr(0, nspace);
                b = text.substr(nspace + 1);
            }
            else if (merge.IsArray() && merge.Size() == 2)
            {
                a = merge[0].AsString();
                b = merge[1].AsString();
            }
            else
            {
                continue;
            }
            m_Ranks.emplace(a + '\x01' + b, irank++);
        }
        for (const Json& added : (*parsed)["added_tokens"].Items())
        {
            m_Special[added["content"].AsString()] = added["id"].AsInt(-1);
        }
        const auto it = m_Special.find("<|endoftext|>");
        m_iEndOfText = it != m_Special.end() ? it->second : -1;

        // GPT-2's byte to printable character map.
        std::vector<int> printable;
        for (int ib = '!'; ib <= '~'; ++ib)
        {
            printable.push_back(ib);
        }
        for (int ib = 0xA1; ib <= 0xAC; ++ib)
        {
            printable.push_back(ib);
        }
        for (int ib = 0xAE; ib <= 0xFF; ++ib)
        {
            printable.push_back(ib);
        }
        bool aPrintable[256] = {};
        for (int ib : printable)
        {
            aPrintable[ib] = true;
        }
        int inext = 0;
        for (int ib = 0; ib < 256; ++ib)
        {
            const uint32_t ucp =
                aPrintable[ib] ? static_cast<uint32_t>(ib) : static_cast<uint32_t>(256 + inext++);
            std::string utf8;
            if (ucp < 0x80)
            {
                utf8 += static_cast<char>(ucp);
            }
            else
            {
                utf8 += static_cast<char>(0xC0 | (ucp >> 6));
                utf8 += static_cast<char>(0x80 | (ucp & 0x3F));
            }
            m_ByteChar[ib] = utf8;
        }
        if (m_Vocab.empty() || m_iEndOfText < 0)
        {
            _Error = "the tokenizer has no vocabulary or no end-of-text token";
            m_Vocab.clear();
            return false;
        }
        return true;
    }

    std::vector<std::string> Gpt2Tokenizer::Bpe(const std::string& _Word) const
    {
        std::vector<std::string> parts;
        for (const Char& c : Decode(_Word))
        {
            parts.push_back(_Word.substr(c.m_nBegin, c.m_nLength));
        }
        while (parts.size() > 1)
        {
            int ibest = INT_MAX;
            std::size_t nat = 0;
            for (std::size_t ni = 0; ni + 1 < parts.size(); ++ni)
            {
                const auto it = m_Ranks.find(parts[ni] + '\x01' + parts[ni + 1]);
                if (it != m_Ranks.end() && it->second < ibest)
                {
                    ibest = it->second;
                    nat = ni;
                }
            }
            if (ibest == INT_MAX)
            {
                break;
            }
            parts[nat] += parts[nat + 1];
            parts.erase(parts.begin() + static_cast<std::ptrdiff_t>(nat) + 1);
        }
        return parts;
    }

    std::vector<int64_t> Gpt2Tokenizer::Encode(const std::string& _Text) const
    {
        std::vector<int64_t> ids;
        auto encodePlain = [&](const std::string& _Piece)
        {
            for (const std::string& word : PreSplit(_Piece))
            {
                std::string mapped;
                for (unsigned char c : word)
                {
                    mapped += m_ByteChar[c];
                }
                for (const std::string& part : Bpe(mapped))
                {
                    const auto it = m_Vocab.find(part);
                    if (it != m_Vocab.end())
                    {
                        ids.push_back(it->second);
                        continue;
                    }
                    // Not a token: its characters one by one (each byte is).
                    for (const Char& c : Decode(part))
                    {
                        const auto one = m_Vocab.find(part.substr(c.m_nBegin, c.m_nLength));
                        if (one != m_Vocab.end())
                        {
                            ids.push_back(one->second);
                        }
                    }
                }
            }
        };
        // Text splits around "[a tag]" (lowercase letters and spaces); a
        // tag that's an added token ("[chuckle]") is that token.
        std::size_t nat = 0;
        std::size_t nsearch = 0;
        while (true)
        {
            const std::size_t nopen = _Text.find('[', nsearch);
            if (nopen == std::string::npos)
            {
                break;
            }
            std::size_t nend = nopen + 1;
            while (nend < _Text.size() &&
                   ((_Text[nend] >= 'a' && _Text[nend] <= 'z') || _Text[nend] == ' '))
            {
                ++nend;
            }
            if (nend == nopen + 1 || nend >= _Text.size() || _Text[nend] != ']')
            {
                nsearch = nopen + 1;
                continue;
            }
            if (nopen > nat)
            {
                encodePlain(_Text.substr(nat, nopen - nat));
            }
            const std::string tag = _Text.substr(nopen, nend - nopen + 1);
            const auto it = m_Special.find(tag);
            if (it != m_Special.end())
            {
                ids.push_back(it->second);
            }
            else
            {
                encodePlain(tag);
            }
            nat = nsearch = nend + 1;
        }
        if (nat < _Text.size())
        {
            encodePlain(_Text.substr(nat));
        }
        ids.push_back(m_iEndOfText);
        ids.push_back(m_iEndOfText);
        return ids;
    }

} // namespace gitgud::speech
