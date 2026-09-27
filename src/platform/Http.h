#pragma once

// -----------------------------------------------------------------------------
// Http: small HTTPS downloads and archive handling for tools the app fetches
// on request (the GitHub CLI for browser sign-in).
//
// Everything BLOCKS: run it on a TaskRunner worker. Only https:// URLs are
// accepted. Windows uses the OS's own WinHTTP, BCrypt, and tar.exe; other
// platforms report "not implemented".
// -----------------------------------------------------------------------------

#include <cstdint>
#include <functional>
#include <string>

namespace gitgud::platform
{

    // GET `_Url` (redirects followed, the system proxy used) into `_Body`.
    // Returns false with `_Error` on a network failure or a non-2xx status.
    bool HttpGet(const std::string& _Url, std::string& _Body, std::string& _Error);

    // HttpGet with an optional extra request header (e.g. "Range: bytes=0-99")
    // and progress: `_OnProgress(bytes so far)` runs as data arrives and can
    // return false to cancel. `_uStatus` gets the HTTP status (206 when a
    // Range was honoured, 200 when the server sent the whole body instead).
    bool HttpGetEx(const std::string& _Url, const std::string& _Header, std::string& _Body,
        unsigned long& _uStatus, const std::function<bool(std::uint64_t)>& _OnProgress,
        std::string& _Error);

    // SHA-256 of `_Data` as lowercase hex, or "" on failure.
    std::string Sha256Hex(const std::string& _Data);

    // Unpack the .zip at `_ZipPath` into `_DestDir` (created if needed).
    bool ExtractZip(const std::string& _ZipPath, const std::string& _DestDir, std::string& _Error);

} // namespace gitgud::platform
