#pragma once

// -----------------------------------------------------------------------------
// SortedTable: a read-only "key<TAB>value" text file, one entry per line,
// sorted by the bytes of its keys, read whole and searched by binary search.
// For large word lists Lua shouldn't hold as tables (the small voice's
// pronunciation dictionaries: tens of thousands of entries each).
// -----------------------------------------------------------------------------

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace gitgud::app
{

    class SortedTable
    {
      public:
        // Read `_Path` (UTF-8). False with `_Error` when it can't be read, a
        // line has no tab, or the keys aren't in byte order.
        bool Load(const std::string& _Path, std::string& _Error);
        // The same from text already in memory (tests).
        bool LoadText(std::string _Text, std::string& _Error);

        // The value for `_Key`, if there is one (valid while this lives).
        std::optional<std::string_view> Find(std::string_view _Key) const;

        std::size_t Size() const
        {
            return m_Lines.size();
        }

      private:
        std::string_view Key(std::size_t _nLine) const;
        std::string_view Value(std::size_t _nLine) const;

        std::string m_Text;
        std::vector<uint32_t> m_Lines; // where each line starts in m_Text
    };

} // namespace gitgud::app
