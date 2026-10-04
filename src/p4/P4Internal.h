#pragma once

// Helpers shared by the P4Workspace*.cpp files (defined in P4Workspace.cpp).

#include "git/LibGit2Internal.h"
#include "p4/P4Command.h"

#include <cstdint>
#include <string>
#include <vector>

namespace gitgud::p4::internal
{

    bool StartsWithNoCase(const std::string& _Text, const std::string& _Prefix);
    std::string ToSlashes(std::string _Path);
    std::int64_t ToInt64(const std::string& _Text);
    // Every "<_Prefix><n>" field of a record, in order (View0, View1, ...).
    std::vector<std::string> Indexed(const Record& _Record, const std::string& _Prefix);
    // A `-o` spec made ready for `-i` (no code / extraTag fields).
    Record SpecForInput(Record _Spec);
    // The number following `_Word` in `_Text` ("Change 12 created" -> "12").
    std::string NumberAfter(const std::string& _Text, const std::string& _Word);
    git::internal::FileVersion Version(const std::string& _Text, bool _bExists);
    std::string ToLf(const std::string& _Text);
    std::vector<std::string> SplitLines(const std::string& _Text);

} // namespace gitgud::p4::internal
