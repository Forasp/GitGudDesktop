#pragma once

// -----------------------------------------------------------------------------
// UpdateCore: the pieces of updating shared by the app and gitgud-patcher.exe.
// Only the standard library and Windows' own BCrypt / process APIs, so the
// patcher stays small (no libgit2, SDL, or CEGUI).
//
// Manifests are plain text, one record per line:
//
//     gitgud-update 1                       (or "gitgud-package 1")
//     version 1.3.0
//     published 2026-10-01
//     notes https://github.com/.../releases/tag/v1.3.0
//     pack <url or file name> <size> <sha256>
//     file <sha256> <size> <offset> <packed size> <path>
//     ...
//     signature <base64 ECDSA P-256 signature, IEEE P1363 r||s>
//
// "gitgud-update" is published with each release (the pack holds every file
// raw-deflated at <offset>, <packed size> bytes). "gitgud-package" ships
// inside the package as package-manifest.txt (offsets 0) and records what
// that version installed. The signature covers every byte before its line.
// Paths use '/' and are relative to the install folder.
// -----------------------------------------------------------------------------

#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace gitgud::update
{

    struct ManifestFile
    {
        std::string m_Path;
        std::string m_Sha256;
        std::uint64_t m_uSize = 0;
        std::uint64_t m_uOffset = 0;
        std::uint64_t m_uPacked = 0;
    };

    struct Manifest
    {
        std::string m_Kind; // "gitgud-update" or "gitgud-package"
        std::string m_Version;
        std::string m_Published;
        std::string m_Notes;
        std::string m_PackUrl;
        std::string m_PackSha256;
        std::uint64_t m_uPackSize = 0;
        std::vector<ManifestFile> m_Files;
        std::string m_SignedText; // everything before the signature line
        std::string m_Signature;  // base64; empty when unsigned
    };

    // Parse a manifest. Rejects unknown kinds, bad hashes, and unsafe paths.
    bool ParseManifest(const std::string& _Text, Manifest& _Out, std::string& _Error);

    // Parse and return the text of the manifest file at `_Path`.
    bool ReadManifestFile(const std::filesystem::path& _Path, Manifest& _Out, std::string& _Error);

    // -1, 0, or 1 comparing dotted numeric versions ("1.10.0" > "1.9.2").
    // Anything unparseable compares as 0.0.0.
    int CompareVersions(const std::string& _A, const std::string& _B);

    // Check the manifest's signature against a base64 P-256 public key (X||Y,
    // 64 bytes). False with `_Error` when unsigned, malformed, or invalid.
    bool VerifySignature(
        const Manifest& _Manifest, const std::string& _PublicKeyBase64, std::string& _Error);

    // Relative, '/'-separated, no "..", no drive or root, no ':'.
    bool IsSafeRelativePath(const std::string& _Path);

    bool Base64Decode(const std::string& _Text, std::string& _Out);
    std::string Base64Encode(const std::string& _Data);

    // Lowercase hex SHA-256 of a buffer / a file ("" on failure).
    std::string Sha256Hex(const std::string& _Data);
    std::string Sha256File(const std::filesystem::path& _Path);

    // ---- Applying an update (gitgud-patcher.exe; tests) ---------------------

    struct PatchPlan
    {
        std::filesystem::path m_InstallDir;
        std::filesystem::path m_FilesDir;    // staged new files, by relative path
        std::filesystem::path m_BackupDir;   // originals moved aside while applying
        std::filesystem::path m_JournalPath; // progress, for rollback after a crash
        std::filesystem::path m_ReplacedDir; // copies of files the user had edited
        std::string m_Version;
        std::vector<std::string> m_Replace;    // relative paths to write
        std::vector<std::string> m_Remove;     // relative paths the new version drops
        std::vector<std::string> m_UserEdited; // subset of m_Replace/m_Remove
    };

    // Work out what applying `_New` over `_InstallDir` means. `_Old` is the
    // installed version's package manifest (nullptr if missing): it tells which
    // files the old version owned (so dropped ones can be removed) and which of
    // them the user has edited. Every file to write must already be staged in
    // `_Plan.m_FilesDir` with the right hash, or this fails.
    bool BuildPlan(
        const Manifest& _New, const Manifest* _Old, PatchPlan& _Plan, std::string& _Error);

    // Files in `_New` whose installed copy is missing or differs.
    std::vector<ManifestFile> ChangedFiles(
        const Manifest& _New, const std::filesystem::path& _InstallDir);

    // Apply a plan: journaled; on any failure everything is put back and
    // false is returned with `_Error`.
    bool ApplyPlan(const PatchPlan& _Plan, std::string& _Error);

    // Undo an apply that was interrupted (a journal without "done"); clean up
    // after a finished one. True when there was nothing to do or it worked.
    bool RecoverJournal(const std::filesystem::path& _JournalPath,
        const std::filesystem::path& _BackupDir, std::string& _Error);

    // ---- Running copies and the update lock (Windows) -----------------------

    // Process ids running `_ExePath` (compared case-insensitively), except
    // `_uExcludePid`.
    std::vector<unsigned long> RunningCopies(
        const std::filesystem::path& _ExePath, unsigned long _uExcludePid);

    // Name of the lock the patcher holds while it replaces files.
    constexpr const wchar_t* kUpdateLockName = L"Local\\GitGudDesktopUpdateInProgress";

} // namespace gitgud::update
