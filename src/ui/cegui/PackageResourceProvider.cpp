#include "ui/cegui/PackageResourceProvider.h"

#include <CEGUI/DataContainer.h>

#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>

namespace gitgud::ui
{

    namespace
    {

        std::string ToStdString(const CEGUI::String& _S)
        {
#if CEGUI_STRING_CLASS == CEGUI_STRING_CLASS_UTF_32
            return CEGUI::String::convertUtf32ToUtf8(_S.c_str());
#else
            return std::string(_S.c_str());
#endif
        }

    } // namespace

    void PackageResourceProvider::SetFallback(
        const CEGUI::String& _Group, const CEGUI::String& _FallbackGroup)
    {
        m_Fallbacks[_Group] = _FallbackGroup;
    }

    void PackageResourceProvider::AddRecolouredGroup(const CEGUI::String& _Group)
    {
        m_RecolouredGroups.insert(_Group);
    }

    void PackageResourceProvider::SetOverlay(const CEGUI::String& _Group, const std::string& _Directory)
    {
        if (_Directory.empty())
        {
            m_Overlays.erase(_Group);
        }
        else
        {
            m_Overlays[_Group] = _Directory;
        }
        m_Disabled.clear();
    }

    void PackageResourceProvider::Disable(const std::string& _Path)
    {
        m_Disabled.insert(_Path);
    }

    std::vector<std::string> PackageResourceProvider::TakeOverlayReads()
    {
        std::vector<std::string> out;
        out.swap(m_OverlayReads);
        return out;
    }

    void PackageResourceProvider::SetColourMap(ColourMap _Map)
    {
        m_ColourMap = std::move(_Map);
    }

    void PackageResourceProvider::loadRawDataContainer(const CEGUI::String& _Filename,
        CEGUI::RawDataContainer& _Output, const CEGUI::String& _ResourceGroup)
    {
        // CEGUI loads a group-less request from the type's default group, so
        // the group that actually applies is what getFinalFilename resolves.
        CEGUI::String group = _ResourceGroup;
        bool bread = false;
        if (const auto it = m_Overlays.find(group); it != m_Overlays.end())
        {
            const std::string path = it->second + "/" + ToStdString(_Filename);
            std::error_code ec;
            if (m_Disabled.count(path) == 0 &&
                std::filesystem::is_regular_file(std::filesystem::u8path(path), ec))
            {
                std::ifstream in(std::filesystem::u8path(path), std::ios::binary);
                const std::string bytes(
                    (std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
                auto* pdata = new std::uint8_t[bytes.size() + 1];
                std::memcpy(pdata, bytes.data(), bytes.size());
                pdata[bytes.size()] = 0;
                _Output.setData(pdata);
                _Output.setSize(bytes.size());
                m_OverlayReads.push_back(path);
                bread = true;
            }
        }
        if (!bread)
        {
            if (const auto it = m_Fallbacks.find(group); it != m_Fallbacks.end())
            {
                std::error_code ec;
                const std::string path = ToStdString(getFinalFilename(_Filename, group));
                if (!std::filesystem::exists(std::filesystem::u8path(path), ec))
                {
                    group = it->second;
                }
            }
            DefaultResourceProvider::loadRawDataContainer(_Filename, _Output, group);
        }

        if (m_ColourMap.empty() ||
            (m_RecolouredGroups.count(_ResourceGroup) == 0 && m_RecolouredGroups.count(group) == 0))
        {
            return;
        }
        const std::string text(
            reinterpret_cast<const char*>(_Output.getDataPtr()), _Output.getSize());
        const std::string recoloured = Recolour(text, m_ColourMap);
        if (recoloured == text)
        {
            return;
        }
        auto* pdata = new std::uint8_t[recoloured.size()];
        std::memcpy(pdata, recoloured.data(), recoloured.size());
        _Output.release();
        _Output.setData(pdata);
        _Output.setSize(recoloured.size());
    }

} // namespace gitgud::ui
