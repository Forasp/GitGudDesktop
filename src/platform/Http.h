#pragma once

// -----------------------------------------------------------------------------
// Http: small HTTPS downloads and archive handling for tools the app fetches
// on request (the GitHub CLI for browser sign-in).
//
// Everything BLOCKS: run it on a TaskRunner worker. Only https:// URLs are
// accepted. Windows uses the OS's own WinHTTP, BCrypt, and tar.exe; other
// platforms report "not implemented".
// -----------------------------------------------------------------------------

#include <string>

namespace gitgud::platform
{

    // GET `_Url` (redirects followed, the system proxy used) into `_Body`.
    // Returns false with `_Error` on a network failure or a non-2xx status.
    bool HttpGet(const std::string& _Url, std::string& _Body, std::string& _Error);

    // SHA-256 of `_Data` as lowercase hex, or "" on failure.
    std::string Sha256Hex(const std::string& _Data);

    // Unpack the .zip at `_ZipPath` into `_DestDir` (created if needed).
    bool ExtractZip(const std::string& _ZipPath, const std::string& _DestDir, std::string& _Error);

} // namespace gitgud::platform
