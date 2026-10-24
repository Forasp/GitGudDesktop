#include "app/SortedTable.h"

#include <filesystem>
#include <fstream>
#include <iterator>
#include <limits>

namespace fs = std::filesystem;

namespace gitgud::app
{

    bool SortedTable::Load(const std::string& _Path, std::string& _Error)
    {
        std::ifstream in(fs::u8path(_Path), std::ios::binary);
        if (!in)
        {
            _Error = "can't open " + _Path;
            return false;
        }
        std::string text((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        if (in.bad())
        {
            _Error = "can't read " + _Path;
            return false;
        }
        return LoadText(std::move(text), _Error);
    }

    bool SortedTable::LoadText(std::string _Text, std::string& _Error)
    {
        if (_Text.size() >= std::numeric_limits<uint32_t>::max())
        {
            _Error = "too big";
            return false;
        }
        m_Text = std::move(_Text);
        m_Lines.clear();
        std::size_t nstart = 0;
        while (nstart < m_Text.size())
        {
            std::size_t nend = m_Text.find('\n', nstart);
            if (nend == std::string::npos)
            {
                nend = m_Text.size();
            }
            if (nend > nstart)
            {
                const std::size_t ntab = m_Text.find('\t', nstart);
                if (ntab == std::string::npos || ntab > nend)
                {
                    _Error = "line " + std::to_string(m_Lines.size() + 1) + " has no tab";
                    m_Lines.clear();
                    return false;
                }
                m_Lines.push_back(static_cast<uint32_t>(nstart));
                if (m_Lines.size() > 1 && !(Key(m_Lines.size() - 2) < Key(m_Lines.size() - 1)))
                {
                    _Error = "line " + std::to_string(m_Lines.size()) + " is out of order";
                    m_Lines.clear();
                    return false;
                }
            }
            nstart = nend + 1;
        }
        return true;
    }

    std::optional<std::string_view> SortedTable::Find(std::string_view _Key) const
    {
        std::size_t nlow = 0;
        std::size_t nhigh = m_Lines.size();
        while (nlow < nhigh)
        {
            const std::size_t nmid = nlow + (nhigh - nlow) / 2;
            const std::string_view key = Key(nmid);
            if (key < _Key)
            {
                nlow = nmid + 1;
            }
            else if (_Key < key)
            {
                nhigh = nmid;
            }
            else
            {
                return Value(nmid);
            }
        }
        return std::nullopt;
    }

    std::string_view SortedTable::Key(std::size_t _nLine) const
    {
        const std::size_t nstart = m_Lines[_nLine];
        return std::string_view(m_Text).substr(nstart, m_Text.find('\t', nstart) - nstart);
    }

    std::string_view SortedTable::Value(std::size_t _nLine) const
    {
        const std::size_t ntab = m_Text.find('\t', m_Lines[_nLine]) + 1;
        std::size_t nend = m_Text.find('\n', ntab);
        if (nend == std::string::npos)
        {
            nend = m_Text.size();
        }
        if (nend > ntab && m_Text[nend - 1] == '\r')
        {
            --nend;
        }
        return std::string_view(m_Text).substr(ntab, nend - ntab);
    }

} // namespace gitgud::app
