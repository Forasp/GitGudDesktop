#include "speech/Text.h"

#include <cctype>

namespace gitgud::speech
{

    namespace
    {

        bool WordChar(unsigned char _C)
        {
            return std::isalnum(_C) || _C == '\'' || _C >= 0x80;
        }

        std::vector<std::string> PhraseWords(const std::string& _Phrase)
        {
            std::vector<std::string> out;
            for (const Word& word : SplitWords(_Phrase))
            {
                out.push_back(word.m_Norm);
            }
            return out;
        }

    } // namespace

    std::vector<Word> SplitWords(const std::string& _Text)
    {
        std::vector<Word> out;
        std::size_t ni = 0;
        while (ni < _Text.size())
        {
            while (ni < _Text.size() && !WordChar(static_cast<unsigned char>(_Text[ni])))
            {
                ++ni;
            }
            const std::size_t nbegin = ni;
            std::string norm;
            while (ni < _Text.size() && WordChar(static_cast<unsigned char>(_Text[ni])))
            {
                const unsigned char c = static_cast<unsigned char>(_Text[ni++]);
                norm += c < 0x80 ? static_cast<char>(std::tolower(c)) : static_cast<char>(c);
            }
            // Apostrophes used as quotes.
            while (!norm.empty() && norm.front() == '\'')
            {
                norm.erase(0, 1);
            }
            while (!norm.empty() && norm.back() == '\'')
            {
                norm.pop_back();
            }
            if (!norm.empty())
            {
                out.push_back({norm, nbegin, ni});
            }
        }
        return out;
    }

    std::string NormalizePhrase(const std::string& _Text)
    {
        std::string out;
        for (const Word& word : SplitWords(_Text))
        {
            if (!out.empty())
            {
                out += ' ';
            }
            out += word.m_Norm;
        }
        return out;
    }

    std::vector<std::size_t> FindPhrase(const std::vector<Word>& _Words, const std::string& _Phrase)
    {
        std::vector<std::size_t> hits;
        const std::vector<std::string> phrase = PhraseWords(_Phrase);
        if (phrase.empty() || phrase.size() > _Words.size())
        {
            return hits;
        }
        for (std::size_t ni = 0; ni + phrase.size() <= _Words.size(); ++ni)
        {
            bool bmatch = true;
            for (std::size_t nk = 0; nk < phrase.size() && bmatch; ++nk)
            {
                bmatch = _Words[ni + nk].m_Norm == phrase[nk];
            }
            if (bmatch)
            {
                hits.push_back(ni);
            }
        }
        return hits;
    }

    bool ContainsPhrase(const std::string& _Text, const std::string& _Phrase)
    {
        return !FindPhrase(SplitWords(_Text), _Phrase).empty();
    }

    bool StartsWithPhrase(const std::string& _Text, const std::string& _Phrase)
    {
        const std::vector<std::size_t> hits = FindPhrase(SplitWords(_Text), _Phrase);
        return !hits.empty() && hits.front() == 0;
    }

    bool EndsWithPhrase(const std::string& _Text, const std::string& _Phrase)
    {
        const std::vector<Word> words = SplitWords(_Text);
        const std::vector<std::size_t> hits = FindPhrase(words, _Phrase);
        return !hits.empty() && hits.back() + PhraseWords(_Phrase).size() == words.size();
    }

    std::string RewriteMishearings(const std::string& _Text,
        const std::vector<std::string>& _Mishearings, const std::string& _WakeWord)
    {
        std::string out = _Text;
        for (const std::string& mishearing : _Mishearings)
        {
            const std::size_t ncount = PhraseWords(mishearing).size();
            if (ncount == 0 || NormalizePhrase(mishearing) == NormalizePhrase(_WakeWord))
            {
                continue;
            }
            for (int iguard = 0; iguard < 64; ++iguard)
            {
                const std::vector<Word> words = SplitWords(out);
                const std::vector<std::size_t> hits = FindPhrase(words, mishearing);
                if (hits.empty())
                {
                    break;
                }
                const std::size_t ni = hits.front();
                out.replace(words[ni].m_nBegin, words[ni + ncount - 1].m_nEnd - words[ni].m_nBegin,
                    _WakeWord);
            }
        }
        return out;
    }

    bool StripTrailingPhrase(std::string& _Text, const std::string& _Phrase)
    {
        const std::vector<Word> words = SplitWords(_Text);
        const std::vector<std::size_t> hits = FindPhrase(words, _Phrase);
        const std::size_t ncount = PhraseWords(_Phrase).size();
        if (hits.empty() || hits.back() + ncount != words.size())
        {
            return false;
        }
        _Text.erase(words[hits.back()].m_nBegin);
        while (
            !_Text.empty() && (_Text.back() == ' ' || _Text.back() == ',' || _Text.back() == ';' ||
                                  _Text.back() == ':' || _Text.back() == '-'))
        {
            _Text.pop_back();
        }
        return true;
    }

    std::vector<std::string> SplitSentences(const std::string& _Text)
    {
        std::vector<std::string> out;
        std::string current;
        for (std::size_t ni = 0; ni < _Text.size(); ++ni)
        {
            const char c = _Text[ni];
            if (c == '\n' || c == '\r')
            {
                if (!current.empty())
                {
                    out.push_back(current);
                }
                current.clear();
                continue;
            }
            current += c;
            const bool bend = (c == '.' || c == '!' || c == '?') &&
                              (ni + 1 == _Text.size() || _Text[ni + 1] == ' ' ||
                                  _Text[ni + 1] == '\n' || _Text[ni + 1] == '"');
            if (bend)
            {
                while (ni + 1 < _Text.size() && _Text[ni + 1] == '"')
                {
                    current += _Text[++ni];
                }
                out.push_back(current);
                current.clear();
            }
        }
        if (!current.empty())
        {
            out.push_back(current);
        }
        std::vector<std::string> trimmed;
        for (const std::string& sentence : out)
        {
            const std::size_t na = sentence.find_first_not_of(" \t");
            if (na == std::string::npos)
            {
                continue;
            }
            const std::size_t nb = sentence.find_last_not_of(" \t");
            trimmed.push_back(sentence.substr(na, nb - na + 1));
        }
        return trimmed;
    }

    int EstimateTokens(const std::string& _Text)
    {
        return static_cast<int>((_Text.size() + 3) / 4);
    }

} // namespace gitgud::speech
