#include "app/UiPackages.h"

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <utility>

namespace gitgud::app
{

    namespace
    {

        namespace fs = std::filesystem;

        constexpr const char* kPathPrefix = "path:";
        constexpr const char* kConfigFile = "ui";

        std::string g_OverlayBase;

        std::string Trim(const std::string& _S)
        {
            const auto nfirst = _S.find_first_not_of(" \t\r\n");
            if (nfirst == std::string::npos)
            {
                return {};
            }
            const auto nlast = _S.find_last_not_of(" \t\r\n");
            return _S.substr(nfirst, nlast - nfirst + 1);
        }

        std::string Slashes(std::string _S)
        {
            std::replace(_S.begin(), _S.end(), '\\', '/');
            while (_S.size() > 1 && _S.back() == '/')
            {
                _S.pop_back();
            }
            return _S;
        }

        bool IsFile(const fs::path& _Path)
        {
            std::error_code ec;
            return fs::is_regular_file(_Path, ec);
        }

        // "key=value" lines; '#' starts a comment line.
        void ReadIni(const fs::path& _File, UiPackage& _Out)
        {
            std::ifstream in(_File, std::ios::binary);
            std::string line;
            while (std::getline(in, line))
            {
                line = Trim(line);
                if (line.empty() || line[0] == '#')
                {
                    continue;
                }
                const auto neq = line.find('=');
                if (neq == std::string::npos)
                {
                    continue;
                }
                const std::string key = Trim(line.substr(0, neq));
                const std::string value = Trim(line.substr(neq + 1));
                if (key == "name")
                {
                    _Out.m_Name = value;
                }
                else if (key == "description")
                {
                    _Out.m_Description = value;
                }
                else if (key == "hidden")
                {
                    _Out.m_bHidden = value == "true";
                }
            }
        }

    } // namespace

    void SetUiOverlayBase(const std::string& _ConfigDir)
    {
        g_OverlayBase = _ConfigDir.empty() ? std::string() : Slashes(_ConfigDir);
    }

    std::string PackageFile(const UiPackage& _Package, const std::string& _Relative)
    {
        if (!_Package.m_OverlayRoot.empty())
        {
            const fs::path over = fs::u8path(_Package.m_OverlayRoot) / fs::u8path(_Relative);
            if (IsFile(over))
            {
                return Slashes(over.u8string());
            }
        }
        return _Package.m_Root + "/" + _Relative;
    }

    std::vector<std::string> OverlayFiles(const UiPackage& _Package)
    {
        std::vector<std::string> out;
        if (_Package.m_OverlayRoot.empty())
        {
            return out;
        }
        const fs::path root = fs::u8path(_Package.m_OverlayRoot);
        std::error_code ec;
        for (fs::recursive_directory_iterator it(root, ec), end; !ec && it != end; it.increment(ec))
        {
            if (it->is_regular_file(ec))
            {
                out.push_back(Slashes(it->path().lexically_relative(root).u8string()));
            }
        }
        std::sort(out.begin(), out.end());
        return out;
    }

    std::optional<UiPackage> LoadUiPackage(const std::string& _Root, const std::string& _Id)
    {
        const fs::path root = fs::u8path(_Root);
        if (!IsFile(root / "scripts" / "main.lua") || !IsFile(root / "layouts" / "main.xml"))
        {
            return std::nullopt;
        }

        UiPackage package;
        package.m_Id = _Id;
        package.m_Root = Slashes(root.u8string());
        package.m_Name = root.filename().u8string();
        ReadIni(root / "ui.ini", package);
        return package;
    }

    std::vector<UiPackage> ListUiPackages(const std::string& _ResourceRoot)
    {
        std::vector<UiPackage> out;

        if (auto base = LoadUiPackage(_ResourceRoot, kDefaultUiId))
        {
            base->m_bBuiltIn = true;
            out.push_back(*base);
        }

        std::vector<fs::path> folders;
        std::error_code ec;
        for (fs::directory_iterator it(fs::u8path(_ResourceRoot) / "uis", ec), end;
            !ec && it != end; it.increment(ec))
        {
            if (it->is_directory(ec))
            {
                folders.push_back(it->path());
            }
        }
        std::sort(folders.begin(), folders.end());

        for (const fs::path& folder : folders)
        {
            if (auto package = LoadUiPackage(folder.u8string(), folder.filename().u8string()))
            {
                package->m_bBuiltIn = true;
                out.push_back(*package);
            }
        }
        if (!g_OverlayBase.empty())
        {
            for (UiPackage& package : out)
            {
                package.m_OverlayRoot = g_OverlayBase + "/" + package.m_Id + "/ui";
            }
        }
        return out;
    }

    std::optional<UiPackage> ResolveUiPackage(
        const std::string& _Spec, const std::string& _ResourceRoot)
    {
        const std::string spec = Trim(_Spec);
        if (spec.rfind(kPathPrefix, 0) == 0)
        {
            const std::string folder = Slashes(spec.substr(std::string(kPathPrefix).size()));
            if (folder.empty())
            {
                return std::nullopt;
            }
            return LoadUiPackage(folder, std::string(kPathPrefix) + folder);
        }

        for (UiPackage& package : ListUiPackages(_ResourceRoot))
        {
            if (package.m_Id == spec)
            {
                return package;
            }
        }
        return std::nullopt;
    }

    std::string ReadUiChoice(const std::string& _ConfigDir)
    {
        std::ifstream in(fs::u8path(_ConfigDir) / kConfigFile, std::ios::binary);
        std::string line;
        while (std::getline(in, line))
        {
            line = Trim(line);
            if (line.rfind("ui=", 0) == 0)
            {
                return Trim(line.substr(3));
            }
        }
        return {};
    }

    bool WriteUiChoice(const std::string& _ConfigDir, const std::string& _Spec)
    {
        std::error_code ec;
        fs::create_directories(fs::u8path(_ConfigDir), ec);
        std::ofstream out(fs::u8path(_ConfigDir) / kConfigFile, std::ios::binary | std::ios::trunc);
        if (!out)
        {
            return false;
        }
        out << "ui=" << _Spec << "\n";
        return static_cast<bool>(out);
    }

    std::vector<std::string> ListThemes(const UiPackage& _Package)
    {
        std::vector<std::string> names;
        for (const std::string& root : {_Package.m_Root, _Package.m_OverlayRoot})
        {
            if (root.empty())
            {
                continue;
            }
            std::error_code ec;
            for (fs::directory_iterator it(fs::u8path(root) / "themes", ec), end;
                !ec && it != end; it.increment(ec))
            {
                if (it->is_regular_file(ec) && it->path().extension() == ".ini")
                {
                    names.push_back(it->path().stem().u8string());
                }
            }
        }
        std::sort(names.begin(), names.end());
        names.erase(std::unique(names.begin(), names.end()), names.end());
        return names;
    }

    namespace
    {

        constexpr const char* kThemeFile = "theme";

        // "<package id>=<theme>" lines.
        std::vector<std::pair<std::string, std::string>> ReadThemeChoices(
            const std::string& _ConfigDir)
        {
            std::vector<std::pair<std::string, std::string>> out;
            std::ifstream in(fs::u8path(_ConfigDir) / kThemeFile, std::ios::binary);
            std::string line;
            while (std::getline(in, line))
            {
                const auto neq = line.rfind('=');
                if (neq != std::string::npos)
                {
                    out.emplace_back(Trim(line.substr(0, neq)), Trim(line.substr(neq + 1)));
                }
            }
            return out;
        }

    } // namespace

    std::string ReadThemeChoice(const std::string& _ConfigDir, const std::string& _PackageId)
    {
        for (const auto& [id, theme] : ReadThemeChoices(_ConfigDir))
        {
            if (id == _PackageId)
            {
                return theme;
            }
        }
        return {};
    }

    bool WriteThemeChoice(
        const std::string& _ConfigDir, const std::string& _PackageId, const std::string& _Theme)
    {
        auto choices = ReadThemeChoices(_ConfigDir);
        bool bfound = false;
        for (auto& [id, theme] : choices)
        {
            if (id == _PackageId)
            {
                theme = _Theme;
                bfound = true;
            }
        }
        if (!bfound)
        {
            choices.emplace_back(_PackageId, _Theme);
        }

        std::error_code ec;
        fs::create_directories(fs::u8path(_ConfigDir), ec);
        std::ofstream out(fs::u8path(_ConfigDir) / kThemeFile, std::ios::binary | std::ios::trunc);
        if (!out)
        {
            return false;
        }
        for (const auto& [id, theme] : choices)
        {
            out << id << "=" << theme << "\n";
        }
        return static_cast<bool>(out);
    }

    std::string ResolveTheme(const UiPackage& _Package, const std::string& _ConfigDir)
    {
        const std::vector<std::string> themes = ListThemes(_Package);
        if (themes.empty())
        {
            return {};
        }
        const std::string chosen = ReadThemeChoice(_ConfigDir, _Package.m_Id);
        for (const char* szname : {chosen.c_str(), kDefaultTheme})
        {
            if (std::find(themes.begin(), themes.end(), szname) != themes.end())
            {
                return szname;
            }
        }
        return themes.front();
    }

    std::string ThemeFile(const UiPackage& _Package, const std::string& _Theme)
    {
        if (_Package.m_Root.empty())
        {
            return {};
        }
        const std::string file =
            PackageFile(_Package, _Theme.empty() ? std::string("colours.ini") : "themes/" + _Theme + ".ini");
        return IsFile(fs::u8path(file)) ? file : std::string();
    }

} // namespace gitgud::app
