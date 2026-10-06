#pragma once

// -----------------------------------------------------------------------------
// UiPackages — the user interfaces GitGud can run.
//
// A UI package is a folder holding its own scripts and layouts:
//
//     <root>/ui.ini          name=..., description=..., hidden=true|false
//     <root>/scripts/main.lua
//     <root>/layouts/main.xml
//     <root>/looknfeel/*.xml (optional skin overrides, loaded over the base skin)
//     <root>/imagesets/*.xml (optional: the package's own images / icons)
//
// The GitGud UI is resources/ itself (id "default"). Built-in alternatives
// live in resources/uis/<id>/ (the Depot UI, the UI picker). Users can
// point GitGud at a package anywhere on disk ("path:<folder>").
//
// Scripts of any package can `require` the GitGud UI's modules (core/,
// ui/, views/): a package's own scripts/ is searched first, then the base
// resources/scripts — so a package overrides a shared module (e.g. its own
// core/palette.lua) just by providing a file of the same name.
//
// The choice is remembered in the per-user config file "ui" as one line,
// "ui=<id>" or "ui=path:<folder>". No file = first launch: the picker runs.
// -----------------------------------------------------------------------------

#include <optional>
#include <string>
#include <vector>

namespace gitgud::app
{

    struct UiPackage
    {
        std::string m_Id;          // "default", "depot", or "path:<folder>" for custom packages
        std::string m_Name;        // display name (ui.ini `name`, else the folder name)
        std::string m_Description; // ui.ini `description`
        std::string m_Root;        // folder holding scripts/ and layouts/ (forward slashes)
        bool m_bBuiltIn = false;   // shipped in resources/
        bool m_bHidden = false;    // not offered as a choice (the picker itself)

        std::string ScriptsDir() const
        {
            return m_Root + "/scripts";
        }

        std::string LayoutsDir() const
        {
            return m_Root + "/layouts";
        }
    };

    // Id of the first-launch / "Switch user interface" chooser.
    inline constexpr const char* kUiPickerId = "picker";
    inline constexpr const char* kDefaultUiId = "default";

    // Read a package folder. Fails (nullopt) unless it has scripts/main.lua and
    // layouts/main.xml. `_Id` becomes the package id.
    std::optional<UiPackage> LoadUiPackage(const std::string& _Root, const std::string& _Id);

    // The GitGud UI plus every package under <resourceRoot>/uis/, built-ins
    // first. Hidden packages are included (callers filter on m_bHidden).
    std::vector<UiPackage> ListUiPackages(const std::string& _ResourceRoot);

    // Resolve "default", a built-in id, or "path:<folder>". nullopt if it
    // doesn't exist or isn't a valid package.
    std::optional<UiPackage> ResolveUiPackage(
        const std::string& _Spec, const std::string& _ResourceRoot);

    // The remembered choice from the config file ("" = none: first launch).
    std::string ReadUiChoice(const std::string& _ConfigDir);
    // Remember a choice. Returns false if the file couldn't be written.
    bool WriteUiChoice(const std::string& _ConfigDir, const std::string& _Spec);

} // namespace gitgud::app
