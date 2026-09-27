// Tests for update/UpdateCore.h: manifests, signatures, and applying a
// staged update with rollback.

#include <catch2/catch_test_macros.hpp>

#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <bcrypt.h>

#include <atomic>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>

#include "platform/Http.h"
#include "update/UpdateCore.h"

namespace fs = std::filesystem;
namespace update = gitgud::update;

namespace
{

    // A throwaway folder, removed afterwards.
    struct TempDir
    {
        fs::path m_Path;

        TempDir()
        {
            static std::atomic<int> s_iCounter{0};
            m_Path = fs::temp_directory_path() /
                     ("gitgud-update-test-" + std::to_string(GetCurrentProcessId()) + "-" +
                         std::to_string(s_iCounter++));
            fs::remove_all(m_Path);
            fs::create_directories(m_Path);
        }

        ~TempDir()
        {
            std::error_code ec;
            fs::remove_all(m_Path, ec);
        }
    };

    void Write(const fs::path& _Path, const std::string& _Text)
    {
        fs::create_directories(_Path.parent_path());
        std::ofstream out(_Path, std::ios::binary | std::ios::trunc);
        out << _Text;
    }

    std::string Read(const fs::path& _Path)
    {
        std::ifstream in(_Path, std::ios::binary);
        std::ostringstream ss;
        ss << in.rdbuf();
        return ss.str();
    }

    std::string FileLine(const std::string& _Path, const std::string& _Content)
    {
        return "file " + update::Sha256Hex(_Content) + " " + std::to_string(_Content.size()) +
               " 0 0 " + _Path + "\n";
    }

    // A P-256 key pair from BCrypt, standing in for the release signing key.
    class TestKey
    {
      public:
        TestKey()
        {
            REQUIRE(
                BCryptOpenAlgorithmProvider(&m_hAlg, BCRYPT_ECDSA_P256_ALGORITHM, nullptr, 0) == 0);
            REQUIRE(BCryptGenerateKeyPair(m_hAlg, &m_hKey, 256, 0) == 0);
            REQUIRE(BCryptFinalizeKeyPair(m_hKey, 0) == 0);
            ULONG ulsize = 0;
            REQUIRE(BCryptExportKey(
                        m_hKey, nullptr, BCRYPT_ECCPUBLIC_BLOB, nullptr, 0, &ulsize, 0) == 0);
            std::string blob(ulsize, '\0');
            REQUIRE(BCryptExportKey(m_hKey, nullptr, BCRYPT_ECCPUBLIC_BLOB,
                        reinterpret_cast<PUCHAR>(blob.data()), ulsize, &ulsize, 0) == 0);
            m_PublicKey = update::Base64Encode(blob.substr(sizeof(BCRYPT_ECCKEY_BLOB)));
        }

        TestKey(const TestKey&) = delete;
        TestKey& operator=(const TestKey&) = delete;

        ~TestKey()
        {
            BCryptDestroyKey(m_hKey);
            BCryptCloseAlgorithmProvider(m_hAlg, 0);
        }

        // `_Text` plus its signature line.
        std::string Sign(const std::string& _Text) const
        {
            const std::string hex = update::Sha256Hex(_Text);
            std::string digest;
            for (std::size_t i = 0; i < hex.size(); i += 2)
            {
                digest.push_back(static_cast<char>(std::stoi(hex.substr(i, 2), nullptr, 16)));
            }
            std::string signature(64, '\0');
            ULONG ulsize = 0;
            REQUIRE(BCryptSignHash(m_hKey, nullptr, reinterpret_cast<PUCHAR>(digest.data()), 32,
                        reinterpret_cast<PUCHAR>(signature.data()), 64, &ulsize, 0) == 0);
            return _Text + "signature " + update::Base64Encode(signature) + "\n";
        }

        const std::string& PublicKey() const
        {
            return m_PublicKey;
        }

      private:
        BCRYPT_ALG_HANDLE m_hAlg = nullptr;
        BCRYPT_KEY_HANDLE m_hKey = nullptr;
        std::string m_PublicKey;
    };

    const std::string kPackSha(64, 'a');

} // namespace

TEST_CASE("Versions compare numerically", "[update]")
{
    CHECK(update::CompareVersions("1.2.0", "1.10.0") < 0);
    CHECK(update::CompareVersions("1.10.0", "1.9.9") > 0);
    CHECK(update::CompareVersions("1.2", "1.2.0") == 0);
    CHECK(update::CompareVersions("2.0.0", "1.99.99") > 0);
    CHECK(update::CompareVersions("garbage", "0.0.0") == 0);
}

TEST_CASE("Only safe relative paths are accepted", "[update]")
{
    CHECK(update::IsSafeRelativePath("gitgud.exe"));
    CHECK(update::IsSafeRelativePath("resources/scripts/main.lua"));
    CHECK(update::IsSafeRelativePath("docs/with space.md"));
    CHECK_FALSE(update::IsSafeRelativePath("../evil.dll"));
    CHECK_FALSE(update::IsSafeRelativePath("a/../../b"));
    CHECK_FALSE(update::IsSafeRelativePath("/abs"));
    CHECK_FALSE(update::IsSafeRelativePath("C:/Windows/x.dll"));
    CHECK_FALSE(update::IsSafeRelativePath("a\\b"));
    CHECK_FALSE(update::IsSafeRelativePath("a//b"));
    CHECK_FALSE(update::IsSafeRelativePath(""));
}

TEST_CASE("Base64 round-trips", "[update]")
{
    for (const std::string text : {"", "f", "fo", "foo", "foob", "fooba", "foobar"})
    {
        std::string decoded;
        REQUIRE(update::Base64Decode(update::Base64Encode(text), decoded));
        CHECK(decoded == text);
    }
    CHECK(update::Base64Encode("foobar") == "Zm9vYmFy");
}

TEST_CASE("Update manifests parse and reject bad input", "[update]")
{
    const std::string good = "gitgud-update 1\nversion 1.3.0\npublished 2026-10-01\n"
                             "notes https://example.test/notes\n"
                             "pack GitGud-win64.pack 100 " +
                             kPackSha + "\n" + "file " + kPackSha + " 10 0 40 gitgud.exe\n" +
                             "file " + kPackSha + " 5 40 60 resources/my file.lua\n";
    update::Manifest manifest;
    std::string error;
    REQUIRE(update::ParseManifest(good, manifest, error));
    CHECK(manifest.m_Kind == "gitgud-update");
    CHECK(manifest.m_Version == "1.3.0");
    CHECK(manifest.m_PackUrl == "GitGud-win64.pack");
    CHECK(manifest.m_uPackSize == 100);
    REQUIRE(manifest.m_Files.size() == 2);
    CHECK(manifest.m_Files[1].m_Path == "resources/my file.lua");
    CHECK(manifest.m_Files[1].m_uOffset == 40);
    CHECK(manifest.m_Signature.empty());

    CHECK_FALSE(update::ParseManifest("gitgud-update 2\nversion 1.0.0\n", manifest, error));
    CHECK_FALSE(
        update::ParseManifest(good + "file " + kPackSha + " 1 0 1 ../x\n", manifest, error));
    CHECK_FALSE(
        update::ParseManifest(good + "file " + kPackSha + " 1 99 5 late.bin\n", manifest, error));
    CHECK_FALSE(update::ParseManifest(
        good + "file " + kPackSha + " 10 0 40 GITGUD.EXE\n", manifest, error));
    CHECK_FALSE(update::ParseManifest("gitgud-update 1\nversion 1.0.0\n", manifest, error));
}

TEST_CASE("Manifest signatures are verified", "[update]")
{
    TestKey key;
    TestKey other;
    const std::string body = "gitgud-update 1\nversion 1.3.0\npack p.pack 10 " + kPackSha + "\n" +
                             "file " + kPackSha + " 3 0 5 a.txt\n";
    const std::string signedText = key.Sign(body);

    update::Manifest manifest;
    std::string error;
    REQUIRE(update::ParseManifest(signedText, manifest, error));
    CHECK(manifest.m_SignedText == body);
    CHECK(update::VerifySignature(manifest, key.PublicKey(), error));
    CHECK_FALSE(update::VerifySignature(manifest, other.PublicKey(), error));
    CHECK_FALSE(update::VerifySignature(manifest, "", error));

    // Any change to the signed part is caught.
    std::string tampered = signedText;
    tampered.replace(tampered.find("1.3.0"), 5, "9.3.0");
    REQUIRE(update::ParseManifest(tampered, manifest, error));
    CHECK_FALSE(update::VerifySignature(manifest, key.PublicKey(), error));

    // Unsigned manifests are refused.
    REQUIRE(update::ParseManifest(body, manifest, error));
    CHECK_FALSE(update::VerifySignature(manifest, key.PublicKey(), error));
}

namespace
{

    // An install of "version 1" plus a staged "version 2":
    //   same.txt     unchanged          changed.txt  new content
    //   sub/new.txt  added              gone.txt     dropped by version 2
    //   edited.txt   changed upstream and edited by the user
    struct Scenario
    {
        TempDir m_Root;
        update::Manifest m_Old;
        update::Manifest m_New;
        update::PatchPlan m_Plan;

        Scenario()
        {
            const fs::path install = m_Root.m_Path / "install";
            const fs::path staged = m_Root.m_Path / "staged";
            Write(install / "same.txt", "same");
            Write(install / "changed.txt", "old");
            Write(install / "gone.txt", "gone");
            Write(install / "edited.txt", "user's edit");
            Write(install / "unknown.txt", "not ours");

            const std::string oldText =
                "gitgud-package 1\nversion 1.0.0\n" + FileLine("same.txt", "same") +
                FileLine("changed.txt", "old") + FileLine("gone.txt", "gone") +
                FileLine("edited.txt", "edited v1");
            const std::string newText =
                "gitgud-package 1\nversion 2.0.0\n" + FileLine("same.txt", "same") +
                FileLine("changed.txt", "new") + FileLine("sub/new.txt", "brand new") +
                FileLine("edited.txt", "edited v2");
            std::string error;
            REQUIRE(update::ParseManifest(oldText, m_Old, error));
            REQUIRE(update::ParseManifest(newText, m_New, error));

            Write(staged / "files" / "changed.txt", "new");
            Write(staged / "files" / "sub" / "new.txt", "brand new");
            Write(staged / "files" / "edited.txt", "edited v2");

            m_Plan.m_InstallDir = install;
            m_Plan.m_FilesDir = staged / "files";
            m_Plan.m_BackupDir = staged / "backup";
            m_Plan.m_JournalPath = staged / "journal.txt";
            m_Plan.m_ReplacedDir = m_Root.m_Path / "edited";
        }

        fs::path Install(const std::string& _Relative) const
        {
            return m_Plan.m_InstallDir / fs::u8path(_Relative);
        }
    };

} // namespace

TEST_CASE("A plan lists changed, added, dropped, and user-edited files", "[update]")
{
    Scenario s;
    std::string error;
    REQUIRE(update::BuildPlan(s.m_New, &s.m_Old, s.m_Plan, error));
    CHECK(
        s.m_Plan.m_Replace == std::vector<std::string>{"changed.txt", "sub/new.txt", "edited.txt"});
    CHECK(s.m_Plan.m_Remove == std::vector<std::string>{"gone.txt"});
    CHECK(s.m_Plan.m_UserEdited == std::vector<std::string>{"edited.txt"});

    // A missing staged file stops the plan.
    fs::remove(s.m_Plan.m_FilesDir / "changed.txt");
    CHECK_FALSE(update::BuildPlan(s.m_New, &s.m_Old, s.m_Plan, error));
}

TEST_CASE("Applying a plan updates the install and keeps user edits", "[update]")
{
    Scenario s;
    std::string error;
    REQUIRE(update::BuildPlan(s.m_New, &s.m_Old, s.m_Plan, error));
    REQUIRE(update::ApplyPlan(s.m_Plan, error));

    CHECK(Read(s.Install("same.txt")) == "same");
    CHECK(Read(s.Install("changed.txt")) == "new");
    CHECK(Read(s.Install("sub/new.txt")) == "brand new");
    CHECK(Read(s.Install("edited.txt")) == "edited v2");
    CHECK_FALSE(fs::exists(s.Install("gone.txt")));
    CHECK(Read(s.Install("unknown.txt")) == "not ours"); // never touch files we didn't install
    CHECK(Read(s.m_Plan.m_ReplacedDir / "edited.txt") == "user's edit");
    CHECK_FALSE(fs::exists(s.m_Plan.m_JournalPath));
    CHECK_FALSE(fs::exists(s.m_Plan.m_BackupDir));
    CHECK(update::ChangedFiles(s.m_New, s.m_Plan.m_InstallDir).empty());
}

TEST_CASE("A failed apply puts everything back", "[update]")
{
    Scenario s;
    std::string error;
    REQUIRE(update::BuildPlan(s.m_New, &s.m_Old, s.m_Plan, error));

    // Hold edited.txt open without delete sharing: it can't be moved, so the
    // apply fails after changed.txt and sub/new.txt were already placed.
    HANDLE hlock = CreateFileW(s.Install("edited.txt").c_str(), GENERIC_READ, FILE_SHARE_READ,
        nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    REQUIRE(hlock != INVALID_HANDLE_VALUE);
    const bool bapplied = update::ApplyPlan(s.m_Plan, error);
    CloseHandle(hlock);

    CHECK_FALSE(bapplied);
    CHECK_FALSE(error.empty());
    CHECK(Read(s.Install("changed.txt")) == "old");
    CHECK_FALSE(fs::exists(s.Install("sub/new.txt")));
    CHECK(Read(s.Install("gone.txt")) == "gone");
    CHECK(Read(s.Install("edited.txt")) == "user's edit");
    CHECK_FALSE(fs::exists(s.Install("changed.txt.gg-new")));
}

TEST_CASE("An interrupted apply is rolled back on recovery", "[update]")
{
    Scenario s;
    // What a crash right after replacing changed.txt leaves behind.
    const fs::path backup = s.m_Plan.m_BackupDir;
    fs::create_directories(backup);
    fs::rename(s.Install("changed.txt"), backup / "changed.txt");
    Write(s.Install("changed.txt"), "new");
    Write(s.Install("sub/new.txt.gg-new"), "half");
    Write(s.m_Plan.m_JournalPath,
        "update 2.0.0\ninstall " + s.m_Plan.m_InstallDir.u8string() +
            "\nmoved changed.txt\nplaced changed.txt\nplaced sub/new.txt\n");

    std::string error;
    REQUIRE(update::RecoverJournal(s.m_Plan.m_JournalPath, backup, error));
    CHECK(Read(s.Install("changed.txt")) == "old");
    CHECK_FALSE(fs::exists(s.Install("sub/new.txt")));
    CHECK_FALSE(fs::exists(s.Install("sub/new.txt.gg-new")));
    CHECK_FALSE(fs::exists(s.m_Plan.m_JournalPath));

    // Nothing to recover: fine.
    CHECK(update::RecoverJournal(s.m_Plan.m_JournalPath, backup, error));
}

// Hidden (needs the internet): run with `gitgud_tests "[online]"`. Release
// downloads redirect to another host; the Range header has to survive that.
TEST_CASE("Range requests work against GitHub release downloads", "[.][online]")
{
    const std::string url =
        "https://github.com/Forasp/GitGudDesktop/releases/download/v1.2.0/GitGud-win64.zip";
    std::string body;
    unsigned long ustatus = 0;
    std::string error;
    REQUIRE(gitgud::platform::HttpGetEx(url, "Range: bytes=0-3", body, ustatus, nullptr, error));
    CHECK(ustatus == 206);
    CHECK(body == std::string("PK\x03\x04", 4)); // a zip starts with a local file header
}
