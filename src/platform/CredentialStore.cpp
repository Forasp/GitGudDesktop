// -----------------------------------------------------------------------------
// Credential store backends: Windows Credential Manager, the macOS Keychain,
// and the Secret Service (libsecret, loaded at run time) on Linux. The
// factory returns nullptr where there is none (Linux without libsecret);
// callers treat "no store" as "always prompt".
// -----------------------------------------------------------------------------

#include "platform/ICredentialStore.h"

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <wincred.h>

#include <vector>
#elif defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>

#include <utility>
#elif defined(__linux__)
#include <dlfcn.h>
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

#elif defined(__linux__)

    namespace
    {

        // The parts of libsecret's ABI used here (libsecret/secret-schema.h).
        // The library is loaded at run time, so the app builds without its
        // headers and runs where no Secret Service exists.
        struct SecretSchemaAttribute
        {
            const char* m_szName;
            int m_iType; // SECRET_SCHEMA_ATTRIBUTE_STRING = 0
        };

        struct SecretSchema
        {
            const char* m_szName;
            int m_iFlags; // SECRET_SCHEMA_NONE = 0
            SecretSchemaAttribute m_Attributes[32];
            int m_iReserved;
            void* m_pReserved[7];
        };

        using StoreFn = int (*)(const SecretSchema*, const char*, const char*, const char*, void*,
            void**, ...);
        using LookupFn = char* (*)(const SecretSchema*, void*, void**, ...);
        using ClearFn = int (*)(const SecretSchema*, void*, void**, ...);
        using FreeFn = void (*)(char*);

        const SecretSchema kSchema = {"io.github.forasp.Gitgud", 0, {{"host", 0}}, 0, {}};

        // Secret Service backend (GNOME Keyring, KWallet, KeePassXC...) through
        // libsecret. The secret is "<username>\n<password>".
        class SecretServiceStore final : public ICredentialStore
        {
          public:
            SecretServiceStore(void* _pLib, StoreFn _Store, LookupFn _Lookup, ClearFn _Clear,
                FreeFn _Free)
                : m_pLib(_pLib), m_Store(_Store), m_Lookup(_Lookup), m_Clear(_Clear), m_Free(_Free)
            {
            }

            ~SecretServiceStore() override
            {
                dlclose(m_pLib);
            }

            bool Get(const std::string& _Host, Credential& _Out) const override
            {
                char* szsecret = m_Lookup(&kSchema, nullptr, nullptr, "host", _Host.c_str(),
                    static_cast<char*>(nullptr));
                if (!szsecret)
                {
                    return false;
                }
                const std::string secret = szsecret;
                m_Free(szsecret);
                const std::size_t nbreak = secret.find('\n');
                if (nbreak == std::string::npos)
                {
                    return false;
                }
                _Out.m_Username = secret.substr(0, nbreak);
                _Out.m_Password = secret.substr(nbreak + 1);
                return true;
            }

            bool Set(const std::string& _Host, const Credential& _In) override
            {
                const std::string label = "GitGud: " + _Host;
                const std::string secret = _In.m_Username + "\n" + _In.m_Password;
                return m_Store(&kSchema, nullptr, label.c_str(), secret.c_str(), nullptr, nullptr,
                           "host", _Host.c_str(), static_cast<char*>(nullptr)) != 0;
            }

            bool Erase(const std::string& _Host) override
            {
                return m_Clear(&kSchema, nullptr, nullptr, "host", _Host.c_str(),
                           static_cast<char*>(nullptr)) != 0;
            }

          private:
            void* m_pLib;
            StoreFn m_Store;
            LookupFn m_Lookup;
            ClearFn m_Clear;
            FreeFn m_Free;
        };

    } // namespace

    std::unique_ptr<ICredentialStore> MakeCredentialStore()
    {
        void* plib = dlopen("libsecret-1.so.0", RTLD_NOW | RTLD_LOCAL);
        if (!plib)
        {
            return nullptr;
        }
        auto store = reinterpret_cast<StoreFn>(dlsym(plib, "secret_password_store_sync"));
        auto lookup = reinterpret_cast<LookupFn>(dlsym(plib, "secret_password_lookup_sync"));
        auto clear = reinterpret_cast<ClearFn>(dlsym(plib, "secret_password_clear_sync"));
        auto free = reinterpret_cast<FreeFn>(dlsym(plib, "secret_password_free"));
        if (!store || !lookup || !clear || !free)
        {
            dlclose(plib);
            return nullptr;
        }
        return std::make_unique<SecretServiceStore>(plib, store, lookup, clear, free);
    }

#elif defined(__APPLE__)

    namespace
    {

        // Releases a Core Foundation object when it goes out of scope.
        template <typename T> struct CfRef
        {
            T m_Ref = nullptr;

            explicit CfRef(T _Ref) : m_Ref(_Ref)
            {
            }
            ~CfRef()
            {
                if (m_Ref)
                {
                    CFRelease(m_Ref);
                }
            }
            CfRef(const CfRef&) = delete;
            CfRef& operator=(const CfRef&) = delete;
        };

        CFStringRef MakeCfString(const std::string& _Text)
        {
            return CFStringCreateWithBytes(kCFAllocatorDefault,
                reinterpret_cast<const UInt8*>(_Text.data()), static_cast<CFIndex>(_Text.size()),
                kCFStringEncodingUTF8, false);
        }

        // Keychain backend: one generic password per host (service = the
        // store's service name, account = host) in the user's login
        // keychain. The secret is "<username>\n<password>".
        class KeychainStore final : public ICredentialStore
        {
          public:
            explicit KeychainStore(std::string _Service) : m_Service(std::move(_Service))
            {
            }

            bool Get(const std::string& _Host, Credential& _Out) const override
            {
                CfRef<CFMutableDictionaryRef> query(Query(_Host));
                CFDictionarySetValue(query.m_Ref, kSecReturnData, kCFBooleanTrue);
                CFDictionarySetValue(query.m_Ref, kSecMatchLimit, kSecMatchLimitOne);
                CFTypeRef presult = nullptr;
                if (SecItemCopyMatching(query.m_Ref, &presult) != errSecSuccess || !presult)
                {
                    return false;
                }
                CfRef<CFTypeRef> result(presult);
                if (CFGetTypeID(presult) != CFDataGetTypeID())
                {
                    return false;
                }
                const auto pdata = static_cast<CFDataRef>(presult);
                const std::string secret(reinterpret_cast<const char*>(CFDataGetBytePtr(pdata)),
                    static_cast<std::size_t>(CFDataGetLength(pdata)));
                const std::size_t nbreak = secret.find('\n');
                if (nbreak == std::string::npos)
                {
                    return false;
                }
                _Out.m_Username = secret.substr(0, nbreak);
                _Out.m_Password = secret.substr(nbreak + 1);
                return true;
            }

            bool Set(const std::string& _Host, const Credential& _In) override
            {
                const std::string secret = _In.m_Username + "\n" + _In.m_Password;
                CfRef<CFDataRef> data(CFDataCreate(kCFAllocatorDefault,
                    reinterpret_cast<const UInt8*>(secret.data()),
                    static_cast<CFIndex>(secret.size())));

                // Replace the existing item, or add one.
                CfRef<CFMutableDictionaryRef> query(Query(_Host));
                CfRef<CFMutableDictionaryRef> change(CFDictionaryCreateMutable(kCFAllocatorDefault,
                    0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
                CFDictionarySetValue(change.m_Ref, kSecValueData, data.m_Ref);
                const OSStatus iupdated = SecItemUpdate(query.m_Ref, change.m_Ref);
                if (iupdated != errSecItemNotFound)
                {
                    return iupdated == errSecSuccess;
                }
                CfRef<CFStringRef> label(MakeCfString("GitGud: " + _Host));
                CFDictionarySetValue(query.m_Ref, kSecAttrLabel, label.m_Ref);
                CFDictionarySetValue(query.m_Ref, kSecValueData, data.m_Ref);
                return SecItemAdd(query.m_Ref, nullptr) == errSecSuccess;
            }

            bool Erase(const std::string& _Host) override
            {
                CfRef<CFMutableDictionaryRef> query(Query(_Host));
                return SecItemDelete(query.m_Ref) == errSecSuccess;
            }

          private:
            // The attributes that identify a host's item.
            CFMutableDictionaryRef Query(const std::string& _Host) const
            {
                CFMutableDictionaryRef pquery = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
                    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
                CfRef<CFStringRef> service(MakeCfString(m_Service));
                CfRef<CFStringRef> account(MakeCfString(_Host));
                CFDictionarySetValue(pquery, kSecClass, kSecClassGenericPassword);
                CFDictionarySetValue(pquery, kSecAttrService, service.m_Ref);
                CFDictionarySetValue(pquery, kSecAttrAccount, account.m_Ref);
                return pquery;
            }

            std::string m_Service;
        };

    } // namespace

    std::unique_ptr<ICredentialStore> MakeCredentialStore()
    {
        return MakeKeychainStore("GitGud");
    }

    std::unique_ptr<ICredentialStore> MakeKeychainStore(const std::string& _Service)
    {
        return std::make_unique<KeychainStore>(_Service);
    }

#else

    std::unique_ptr<ICredentialStore> MakeCredentialStore()
    {
        return nullptr;
    }

#endif

} // namespace gitgud::platform
