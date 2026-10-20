// Tests for a UI package's colour files and themes: parsing, recolouring
// layout and display text, named tokens, and the remembered theme.

#include <catch2/catch_test_macros.hpp>

#include "app/UiPackages.h"
#include "ui/ColourMap.h"

#include <filesystem>
#include <fstream>
#include <string>

using namespace gitgud::ui;

TEST_CASE("colours.ini parses pairs and skips the rest", "[colourmap]")
{
    const ColourMap map = ParseColourMap("# canvas\n"
                                         "ff17102b = FF123C38\r\n"
                                         "; a comment\n"
                                         "\n"
                                         "FF0E0A1A=FF0B2624\n"
                                         "nonsense\n"
                                         "1234567 = FF000000\n"
                                         "FF1F1738 = not-a-colour\n");
    REQUIRE(map.size() == 2);
    CHECK(map.at("FF17102B") == "FF123C38");
    CHECK(map.at("FF0E0A1A") == "FF0B2624");
}

TEST_CASE("recolour swaps whole colour tokens only", "[colourmap]")
{
    const ColourMap map = ParseColourMap("FF17102B = FF123C38\nFF1C1433 = FF184A45\n");

    CHECK(Recolour("<Property name=\"PanelColour\" value=\"FF17102B\"/>", map) ==
          "<Property name=\"PanelColour\" value=\"FF123C38\"/>");
    CHECK(Recolour("tl:ff1c1433 tr:FF1C1433 bl:FF0E0A1A", map) ==
          "tl:FF184A45 tr:FF184A45 bl:FF0E0A1A");
    CHECK(Recolour("[colour='FF17102B']text", map) == "[colour='FF123C38']text");

    // Part of a longer word: left alone.
    CHECK(Recolour("FF17102B0 xFF17102B FF17102B_x", map) == "FF17102B0 xFF17102B FF17102B_x");
}

TEST_CASE("an empty map leaves text untouched", "[colourmap]")
{
    const std::string text = "<Property value=\"FF17102B\"/>";
    CHECK(Recolour(text, {}) == text);
    CHECK(RecolourMarkup("[colour='$accent']", {}) == "[colour='$accent']");
    CHECK(LoadColourFile("").empty());
}

TEST_CASE("named tokens", "[colourmap]")
{
    const ColourMap map = ParseColourMap("accent = FFE8B866\n"
                                         "add-bg = 29A9BA78\n"
                                         "on_accent = FF2A1E05    # text on accent\n"
                                         "9bad = FF000000\n"
                                         "bad name = FF000000\n");
    CHECK(TokenColour(map, "accent") == "FFE8B866");
    CHECK(TokenColour(map, "add-bg") == "29A9BA78");
    CHECK(TokenColour(map, "on_accent") == "FF2A1E05");
    CHECK(TokenColour(map, "9bad").empty());
    CHECK(TokenColour(map, "bad name").empty());
    CHECK(TokenColour(map, "missing").empty());

    CHECK(Recolour("<Property value=\"$accent\"/>", map) == "<Property value=\"FFE8B866\"/>");
    CHECK(Recolour("tl:$add-bg tr:$accent", map) == "tl:29A9BA78 tr:FFE8B866");
    // An unknown name stays as written.
    CHECK(Recolour("$nothing and $accent", map) == "$nothing and FFE8B866");
}

TEST_CASE("display text only recolours inside markup tags", "[colourmap]")
{
    const ColourMap map = ParseColourMap("accent = FFE8B866\nFF17102B = FF123C38\n");

    // Content that happens to look like a token or a colour stays.
    CHECK(RecolourMarkup("echo $accent FF17102B", map) == "echo $accent FF17102B");
    CHECK(RecolourMarkup("[colour='$accent']name[colour='FF17102B'] $accent", map) ==
          "[colour='FFE8B866']name[colour='FF123C38'] $accent");
    // An escaped bracket isn't a tag.
    CHECK(RecolourMarkup("\\[colour='$accent']", map) == "\\[colour='$accent']");
    // An unclosed bracket is text.
    CHECK(RecolourMarkup("a [b $accent", map) == "a [b $accent");
}

TEST_CASE("themes are listed, remembered, and resolved", "[colourmap]")
{
    namespace fs = std::filesystem;
    using namespace gitgud::app;

    const fs::path root = fs::temp_directory_path() / "gitgud_theme_test";
    fs::remove_all(root);
    const fs::path package = root / "pkg";
    const fs::path config = root / "config";
    fs::create_directories(package / "themes");
    std::ofstream(package / "themes" / "light.ini") << "accent = FFE3A83A\n";
    std::ofstream(package / "themes" / "dark.ini") << "accent = FFE8B866\n";
    std::ofstream(package / "themes" / "notes.txt") << "not a theme\n";

    UiPackage pkg;
    pkg.m_Id = "pkg";
    pkg.m_Root = package.generic_u8string();

    const auto themes = ListThemes(pkg);
    REQUIRE(themes.size() == 2);
    CHECK(themes[0] == "dark");
    CHECK(themes[1] == "light");

    // Nothing remembered: the default theme.
    CHECK(ReadThemeChoice(config.u8string(), "pkg").empty());
    CHECK(ResolveTheme(pkg, config.u8string()) == "dark");

    // Remembered per package; other packages' choices survive a write.
    REQUIRE(WriteThemeChoice(config.u8string(), "other", "blue"));
    REQUIRE(WriteThemeChoice(config.u8string(), "pkg", "light"));
    REQUIRE(WriteThemeChoice(config.u8string(), "pkg", "light"));
    CHECK(ReadThemeChoice(config.u8string(), "pkg") == "light");
    CHECK(ReadThemeChoice(config.u8string(), "other") == "blue");
    CHECK(ResolveTheme(pkg, config.u8string()) == "light");

    // A remembered theme the package no longer has falls back.
    REQUIRE(WriteThemeChoice(config.u8string(), "pkg", "gone"));
    CHECK(ResolveTheme(pkg, config.u8string()) == "dark");

    // The colour file for a theme, and for a package without themes.
    const ColourMap light = LoadColourFile(ThemeFile(pkg, "light"));
    CHECK(TokenColour(light, "accent") == "FFE3A83A");
    CHECK(ThemeFile(pkg, "missing").empty());
    CHECK(ThemeFile(pkg, "").empty()); // no colours.ini
    std::ofstream(package / "colours.ini") << "FF17102B = FF123C38\n";
    CHECK_FALSE(ThemeFile(pkg, "").empty());

    UiPackage plain;
    plain.m_Id = "plain";
    plain.m_Root = (root / "plain").generic_u8string();
    CHECK(ListThemes(plain).empty());
    CHECK(ResolveTheme(plain, config.u8string()).empty());

    fs::remove_all(root);
}

TEST_CASE("a built-in package's customizations win over its own files", "[colourmap]")
{
    namespace fs = std::filesystem;
    using namespace gitgud::app;

    const fs::path root = fs::temp_directory_path() / "gitgud_overlay_test";
    fs::remove_all(root);
    const fs::path resources = root / "resources";
    const fs::path config = root / "config";
    // A minimal GitGud UI and one built-in package.
    fs::create_directories(resources / "scripts");
    fs::create_directories(resources / "layouts");
    std::ofstream(resources / "scripts" / "main.lua") << "-- base\n";
    std::ofstream(resources / "layouts" / "main.xml") << "<x/>\n";
    const fs::path pkg = resources / "uis" / "pkg";
    fs::create_directories(pkg / "scripts");
    fs::create_directories(pkg / "layouts");
    fs::create_directories(pkg / "themes");
    fs::create_directories(pkg / "prompts");
    std::ofstream(pkg / "scripts" / "main.lua") << "-- pkg\n";
    std::ofstream(pkg / "layouts" / "main.xml") << "<x/>\n";
    std::ofstream(pkg / "themes" / "dark.ini") << "accent = FFE8B866\n";
    std::ofstream(pkg / "prompts" / "a.md") << "shipped\n";

    // Overlays off: nothing changes.
    SetUiOverlayBase("");
    auto plain = ResolveUiPackage("pkg", resources.u8string());
    REQUIRE(plain.has_value());
    CHECK(plain->m_OverlayRoot.empty());

    SetUiOverlayBase(config.u8string());
    auto package = ResolveUiPackage("pkg", resources.u8string());
    REQUIRE(package.has_value());
    const std::string overlay = (config / "pkg" / "ui").generic_u8string();
    CHECK(package->m_OverlayRoot == overlay);
    CHECK(OverlayFiles(*package).empty());
    CHECK(PackageFile(*package, "prompts/a.md") == package->m_Root + "/prompts/a.md");

    // Files in the overlay replace the package's and add themes.
    fs::create_directories(fs::u8path(overlay) / "prompts");
    fs::create_directories(fs::u8path(overlay) / "themes");
    std::ofstream(fs::u8path(overlay) / "prompts" / "a.md") << "yours\n";
    std::ofstream(fs::u8path(overlay) / "themes" / "dark.ini") << "accent = FF000001\n";
    std::ofstream(fs::u8path(overlay) / "themes" / "darkblue.ini") << "accent = FF0000FF\n";
    CHECK(PackageFile(*package, "prompts/a.md") == overlay + "/prompts/a.md");
    CHECK(PackageFile(*package, "prompts/b.md") == package->m_Root + "/prompts/b.md");
    const auto themes = ListThemes(*package);
    REQUIRE(themes.size() == 2);
    CHECK(themes[0] == "dark");
    CHECK(themes[1] == "darkblue");
    CHECK(TokenColour(LoadColourFile(ThemeFile(*package, "dark")), "accent") == "FF000001");
    CHECK(TokenColour(LoadColourFile(ThemeFile(*package, "darkblue")), "accent") == "FF0000FF");
    const auto files = OverlayFiles(*package);
    REQUIRE(files.size() == 3);
    CHECK(files[0] == "prompts/a.md");
    CHECK(files[2] == "themes/darkblue.ini");

    // A package anywhere on disk has no overlay (it's the user's already).
    auto custom = ResolveUiPackage("path:" + pkg.generic_u8string(), resources.u8string());
    REQUIRE(custom.has_value());
    CHECK(custom->m_OverlayRoot.empty());

    SetUiOverlayBase("");
    fs::remove_all(root);
}
