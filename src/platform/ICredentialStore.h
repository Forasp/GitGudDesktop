#pragma once

// -----------------------------------------------------------------------------
// ICredentialStore — secure storage for Git server credentials.
//
// libgit2 handles the auth handshake but NOT storage (docs/PRINCIPLES.md,
// principle 8): secrets must never land in plaintext config. Each OS gets a backend:
//   * Windows: Credential Manager (CredRead/CredWrite)   — implemented
//   * macOS:   Keychain                                   — future
//   * Linux:   Secret Service through libsecret (loaded at run time)
//
// Keys are the remote host name (e.g. "git.example.com"), so one credential
// covers every repo on the same server.
// -----------------------------------------------------------------------------

#include <memory>
#include <string>

namespace gitgud::platform
{

    struct Credential
    {
        std::string m_Username;
        std::string m_Password; // or token
    };

    class ICredentialStore
    {
      public:
        virtual ~ICredentialStore() = default;

        // Fetch the stored credential for `host`. Returns false if none exists.
        virtual bool Get(const std::string& _Host, Credential& _Out) const = 0;

        // Store (or replace) the credential for `host`. Returns false on failure.
        virtual bool Set(const std::string& _Host, const Credential& _Cred) = 0;

        // Remove the credential for `host` (e.g. after repeated auth failures).
        virtual bool Erase(const std::string& _Host) = 0;
    };

    // Factory for the current platform's backend; returns nullptr where no secure
    // backend is implemented yet (callers must handle that gracefully).
    std::unique_ptr<ICredentialStore> MakeCredentialStore();

    // Extract the host from a remote URL ("https://git.example.com/r.git" ->
    // "git.example.com"; "git@host:path" -> "host"). Local paths return "".
    std::string HostFromUrl(const std::string& _Url);

} // namespace gitgud::platform
