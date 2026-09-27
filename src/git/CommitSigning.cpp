// -----------------------------------------------------------------------------
// CommitSigning — sign commits the way `git commit -S` does, by handing the
// raw commit to the user's own signing tool:
//
//   gpg.format = openpgp (default)   gpg --status-fd=2 -bsau <user.signingkey>
//   gpg.format = ssh                 ssh-keygen -Y sign -n git -f <key file>
//
// Whether to sign at all is commit.gpgsign. The tools come from gpg.program /
// gpg.ssh.program, else PATH, else Git for Windows' bundled copies.
// -----------------------------------------------------------------------------

#include "git/LibGit2Internal.h"

#include "platform/Process.h"

#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>

namespace gitgud::git::internal
{

    namespace
    {

        namespace fs = std::filesystem;

        std::string ConfigString(git_config* _pCfg, const char* _szKey)
        {
            Buf value;
            if (git_config_get_string_buf(&value.m_B, _pCfg, _szKey) != 0)
            {
                return {};
            }
            return value.Str();
        }

        std::string Trimmed(const std::string& _Text)
        {
            const auto nfirst = _Text.find_first_not_of(" \t\r\n");
            if (nfirst == std::string::npos)
            {
                return {};
            }
            const auto nlast = _Text.find_last_not_of(" \t\r\n");
            return _Text.substr(nfirst, nlast - nfirst + 1);
        }

        std::string ToolFailure(const char* _szTool, const platform::ProcessResult& _Result)
        {
            if (!_Result.m_bStarted)
            {
                return std::string("Signing failed: ") + _Result.m_StartError +
                       ". Install it or turn commit signing off in Options.";
            }
            std::string detail = Trimmed(_Result.m_Error);
            if (detail.empty())
            {
                detail = "exit code " + std::to_string(_Result.m_iExitCode);
            }
            return std::string("Signing with ") + _szTool + " failed: " + detail;
        }

        // `~/.ssh/id_ed25519` -> an absolute path.
        std::string ExpandHome(const std::string& _Path)
        {
            if (_Path.rfind("~/", 0) != 0 && _Path.rfind("~\\", 0) != 0)
            {
                return _Path;
            }
            const char* szhome = std::getenv("USERPROFILE");
            if (!szhome)
            {
                szhome = std::getenv("HOME");
            }
            return szhome ? (fs::u8path(szhome) / fs::u8path(_Path.substr(2))).u8string() : _Path;
        }

        std::string SignWithGpg(
            const SigningConfig& _Config, const std::string& _Content, const std::string& _WorkDir)
        {
            const std::string program = _Config.m_Program.empty() ? "gpg" : _Config.m_Program;
            std::vector<std::string> args = {program, "--status-fd=2", "-bsa"};
            if (!_Config.m_Key.empty())
            {
                args.push_back("-u");
                args.push_back(_Config.m_Key);
            }

            const platform::ProcessResult result = platform::RunProcess(args, _WorkDir, _Content);
            if (!result.m_bStarted || result.m_iExitCode != 0 ||
                result.m_Output.find("-----BEGIN PGP SIGNATURE-----") == std::string::npos)
            {
                throw GitError(ToolFailure("gpg", result));
            }
            return result.m_Output;
        }

        std::string SignWithSsh(
            const SigningConfig& _Config, const std::string& _Content, const std::string& _WorkDir)
        {
            if (_Config.m_Key.empty())
            {
                throw GitError("SSH signing needs user.signingkey (the path of your SSH key)");
            }
            const std::string program =
                _Config.m_Program.empty() ? "ssh-keygen" : _Config.m_Program;

            // ssh-keygen signs a file and writes <file>.sig next to it.
            static std::atomic<unsigned> counter{0};
            const fs::path dataFile =
                fs::temp_directory_path() /
                ("gitgud-sign-" + std::to_string(counter++) + "-" +
                    std::to_string(reinterpret_cast<std::uintptr_t>(&_Content)) + ".txt");
            fs::path sigFile = dataFile;
            sigFile += ".sig";
            {
                std::ofstream out(dataFile, std::ios::binary | std::ios::trunc);
                out.write(_Content.data(), static_cast<std::streamsize>(_Content.size()));
            }

            const platform::ProcessResult result =
                platform::RunProcess({program, "-Y", "sign", "-n", "git", "-f",
                                         ExpandHome(_Config.m_Key), dataFile.u8string()},
                    _WorkDir);

            std::string signature;
            {
                std::ifstream in(sigFile, std::ios::binary);
                std::ostringstream ss;
                ss << in.rdbuf();
                signature = ss.str();
            }
            std::error_code ec;
            fs::remove(dataFile, ec);
            fs::remove(sigFile, ec);

            if (!result.m_bStarted || result.m_iExitCode != 0 ||
                signature.find("-----BEGIN SSH SIGNATURE-----") == std::string::npos)
            {
                throw GitError(ToolFailure("ssh-keygen", result));
            }
            return signature;
        }

    } // namespace

    SigningConfig ReadSigningConfig(git_repository* _pRepo)
    {
        SigningConfig config;
        ConfigPtr cfg;
        if (git_repository_config(&cfg.m_pP, _pRepo) < 0)
        {
            return config;
        }
        ConfigPtr snapshot;
        if (git_config_snapshot(&snapshot.m_pP, cfg.m_pP) < 0)
        {
            return config;
        }

        int ienabled = 0;
        if (git_config_get_bool(&ienabled, snapshot.m_pP, "commit.gpgsign") == 0)
        {
            config.m_bEnabled = ienabled != 0;
        }
        const std::string format = ConfigString(snapshot.m_pP, "gpg.format");
        if (!format.empty())
        {
            config.m_Format = format;
        }
        config.m_Key = ConfigString(snapshot.m_pP, "user.signingkey");
        config.m_Program = config.m_Format == "ssh" ? ConfigString(snapshot.m_pP, "gpg.ssh.program")
                                                    : ConfigString(snapshot.m_pP, "gpg.program");
        return config;
    }

    std::string SignBuffer(
        const SigningConfig& _Config, const std::string& _Content, const std::string& _WorkDir)
    {
        if (_Config.m_Format == "ssh")
        {
            return SignWithSsh(_Config, _Content, _WorkDir);
        }
        if (_Config.m_Format == "x509")
        {
            throw GitError("X.509 commit signing (gpgsm) isn't supported; use openpgp or ssh");
        }
        return SignWithGpg(_Config, _Content, _WorkDir);
    }

} // namespace gitgud::git::internal
