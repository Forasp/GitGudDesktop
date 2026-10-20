#pragma once

// -----------------------------------------------------------------------------
// PackageResourceProvider: CEGUI's file loader, plus what a UI package needs
// to build on the GitGud UI's own files:
//
//  - Fallback groups. A file missing from one resource group is read from
//    another: "layouts" (the running package's folder) falls back to
//    "gitgud-layouts", so a package's layout can import a GitGud UI layout
//    and that layout's own imports still resolve. A package replaces one base
//    layout file by shipping a file of the same name.
//  - Recolouring. While a package's colour map is set (ui/ColourMap.h), the
//    colours in layout and looknfeel files are swapped through it as they
//    load, so the GitGud UI's layouts and skin take the package's palette.
//  - Overlays (app/UiPackages.h: the user's customizations). A file in a
//    group's overlay folder is read instead of the group's own; one that
//    failed to load is turned off (Disable) so the shipped file loads again.
// -----------------------------------------------------------------------------

#include "ui/ColourMap.h"

#include <CEGUI/DefaultResourceProvider.h>

#include <string>
#include <unordered_set>
#include <unordered_map>
#include <vector>

namespace gitgud::ui
{

    class PackageResourceProvider final : public CEGUI::DefaultResourceProvider
    {
      public:
        // Read files missing from _Group out of _FallbackGroup instead.
        void SetFallback(const CEGUI::String& _Group, const CEGUI::String& _FallbackGroup);

        // Recolour files loaded from _Group while a colour map is set.
        void AddRecolouredGroup(const CEGUI::String& _Group);

        // Read _Group's files from _Directory first when they're there ("" turns
        // it off). Clears the files turned off.
        void SetOverlay(const CEGUI::String& _Group, const std::string& _Directory);
        // Never read this overlay file again (it failed to load).
        void Disable(const std::string& _Path);
        // The overlay files read since the last call (and forget them).
        std::vector<std::string> TakeOverlayReads();

        // The running package's colour map (empty: files load as written).
        void SetColourMap(ColourMap _Map);

        const ColourMap& GetColourMap() const
        {
            return m_ColourMap;
        }

        void loadRawDataContainer(const CEGUI::String& _Filename, CEGUI::RawDataContainer& _Output,
            const CEGUI::String& _ResourceGroup) override;

      private:
        std::unordered_map<CEGUI::String, std::string> m_Overlays;
        std::unordered_set<std::string> m_Disabled;
        std::vector<std::string> m_OverlayReads;
        std::unordered_map<CEGUI::String, CEGUI::String> m_Fallbacks;
        std::unordered_set<CEGUI::String> m_RecolouredGroups;
        ColourMap m_ColourMap;
    };

} // namespace gitgud::ui
