// -----------------------------------------------------------------------------
// Credential store backends. Windows Credential Manager today; the factory
// returns nullptr on other platforms until their backends land (Keychain,
// libsecret) — callers treat "no store" as "always prompt".
// -----------------------------------------------------------------------------

#include "platform/ICredentialStore.h"

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <wincred.h>

#include <vector>
#endif

namespace gitgud::platform
{

    std::string HostFromUrl(const std::string& _Url)
    {
        // scheme://[user@]host[:port]/path
        const auto schemeEnd = _Url.find("://");
        if (schemeEnd != std::string::npos)
        {
            std::size_t begin = schemeEnd + 3;
            const auto at = _Url.find('@', begin);
            const auto slash = _Url.find('/', begin);
            if (at != std::string::npos && (slash == std::string::npos || at < slash))
            {
                begin = at + 1;
            }
            std::size_t end = _Url.find_first_of(":/", begin);
            if (end == std::string::npos)
            {
                end = _Url.size();
            }
            return _Url.substr(begin, end - begin);
        }
        // scp-like: user@host:path
        const auto at = _Url.find('@');
        if (at != std::string::npos)
        {
            const auto colon = _Url.find(':', at);
            const std::size_t end = (colon == std::string::npos) ? _Url.size() : colon;
            return _Url.substr(at + 1, end - at - 1);
        }
        return {}; // local path
    }

#if defined(_WIN32)

    namespace
    {

        std::wstring ToWide(const std::string& _S)
        {
            if (_S.empty())
            {
                return {};
            }
            const int in =
                MultiByteToWideChar(CP_UTF8, 0, _S.data(), static_cast<int>(_S.size()), nullptr, 0);
            std::wstring out(in, L'\0');
            MultiByteToWideChar(CP_UTF8, 0, _S.data(), static_cast<int>(_S.size()), out.data(), in);
            return out;
        }

        std::string ToUtf8(const wchar_t* _wszS, int _Chars = -1)
        {
            if (!_wszS)
            {
                return {};
            }
            const int in =
                WideCharToMultiByte(CP_UTF8, 0, _wszS, _Chars, nullptr, 0, nullptr, nullptr);
            if (in <= 0)
            {
                return {};
            }
            std::string out(in, '\0');
            WideCharToMultiByte(CP_UTF8, 0, _wszS, _Chars, out.data(), in, nullptr, nullptr);
            if (_Chars == -1 && !out.empty() && out.back() == '\0')
            {
                out.pop_back();
            }
            return out;
        }

        std::wstring TargetName(const std::string& _Host)
        {
            return L"gitgud:" + ToWide(_Host);
        }

        // Windows Credential Manager backend. Credentials are stored per-user,
        // encrypted by the OS (DPAPI) — never on disk in plaintext.
        class WindowsCredentialStore final : public ICredentialStore
        {
          public:
            bool Get(const std::string& _Host, Credential& _Out) const override
            {
                PCREDENTIALW cred = nullptr;
                if (!CredReadW(TargetName(_Host).c_str(), CRED_TYPE_GENERIC, 0, &cred))
                {
                    return false;
                }
                _Out.m_Username = ToUtf8(cred->UserName);
                // CredentialBlob is a byte buffer; we store UTF-8 there.
                _Out.m_Password.assign(
                    reinterpret_cast<const char*>(cred->CredentialBlob), cred->CredentialBlobSize);
                CredFree(cred);
                return true;
            }

            bool Set(const std::string& _Host, const Credential& _In) override
            {
                const std::wstring target = TargetName(_Host);
                const std::wstring user = ToWide(_In.m_Username);
                // Blob may be referenced but not modified by CredWrite; the const
                // casts are the documented usage pattern.
                CREDENTIALW cred = {};
                cred.Type = CRED_TYPE_GENERIC;
                cred.TargetName = const_cast<LPWSTR>(target.c_str());
                cred.UserName = const_cast<LPWSTR>(user.c_str());
                cred.CredentialBlob =
                    reinterpret_cast<LPBYTE>(const_cast<char*>(_In.m_Password.data()));
                cred.CredentialBlobSize = static_cast<DWORD>(_In.m_Password.size());
                cred.Persist = CRED_PERSIST_LOCAL_MACHINE;
                return CredWriteW(&cred, 0) != 0;
            }

            bool Erase(const std::string& _Host) override
            {
                return CredDeleteW(TargetName(_Host).c_str(), CRED_TYPE_GENERIC, 0) != 0;
            }
        };

    } // namespace

    std::unique_ptr<ICredentialStore> MakeCredentialStore()
    {
        return std::make_unique<WindowsCredentialStore>();
    }

#else

    std::unique_ptr<ICredentialStore> MakeCredentialStore()
    {
        return nullptr; // macOS Keychain / libsecret backends TBD
    }

#endif

} // namespace gitgud::platform
