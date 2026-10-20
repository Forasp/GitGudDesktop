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
//
// Customizations: a built-in package has an overlay folder in the per-user
// config, <config>/<id>/ui/, mirroring its own folder. A file there is used
// instead of the shipped one of the same path (scripts, layouts, looknfeel,
// imagesets, schemes, fonts, themes, prompts, anything the package reads
// through PackageFile), so an update never overwrites it and the shipped
// install stays as it was. The scripts, layouts, and skin fall back to the
// shipped file when an overlay one fails to load (lua/LuaEngine.h,
// ui/cegui/PackageResourceProvider.h).
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
        std::string m_OverlayRoot; // the user's customizations of it ("" for none; forward slashes)
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

    // Where built-in packages' overlays live: <_ConfigDir>/<id>/ui ("" turns
    // overlays off, the default). Set once at start.
    void SetUiOverlayBase(const std::string& _ConfigDir);

    // A package file by its path relative to the package (forward slashes):
    // the overlay's when it has one, else the shipped one (which may not
    // exist).
    std::string PackageFile(const UiPackage& _Package, const std::string& _Relative);

    // The files in the package's overlay, relative paths, sorted.
    std::vector<std::string> OverlayFiles(const UiPackage& _Package);

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

    // Themes ---------------------------------------------------------------------
    // A package can ship colour themes, <root>/themes/<name>.ini, each a colour
    // file (ui/ColourMap.h) that recolours the GitGud UI's files and names the
    // package's own tokens. A package without themes/ may have one
    // <root>/colours.ini instead. The choice is remembered per package in the
    // per-user config file "theme", one "<package id>=<theme>" line each.

    // Used when nothing is remembered and the package has a theme by this name.
    inline constexpr const char* kDefaultTheme = "dark";

    // The package's theme names, sorted ("light", "dark"), the overlay's
    // themes/*.ini included; empty without themes/.
    std::vector<std::string> ListThemes(const UiPackage& _Package);
    // The remembered theme for a package ("" = none).
    std::string ReadThemeChoice(const std::string& _ConfigDir, const std::string& _PackageId);
    // Remember it. False if the file couldn't be written.
    bool WriteThemeChoice(
        const std::string& _ConfigDir, const std::string& _PackageId, const std::string& _Theme);
    // The theme that applies: the remembered one if the package has it, else
    // kDefaultTheme if it has that, else its first; "" for a package without themes.
    std::string ResolveTheme(const UiPackage& _Package, const std::string& _ConfigDir);
    // The colour file to apply for _Theme: <root>/themes/<_Theme>.ini, or for ""
    // <root>/colours.ini (the overlay's first); "" when that file doesn't exist.
    std::string ThemeFile(const UiPackage& _Package, const std::string& _Theme);

} // namespace gitgud::app
