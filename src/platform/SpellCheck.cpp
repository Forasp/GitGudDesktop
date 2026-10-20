#include "platform/SpellCheck.h"

#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <spellcheck.h>
#endif

namespace gitgud::platform
{

#if defined(_WIN32)

    namespace
    {
        constexpr const wchar_t* kLanguage = L"en-US";

        std::wstring Widen(const std::string& _Utf8)
        {
            if (_Utf8.empty())
            {
                return {};
            }
            const int iwide = MultiByteToWideChar(
                CP_UTF8, 0, _Utf8.data(), static_cast<int>(_Utf8.size()), nullptr, 0);
            if (iwide <= 0)
            {
                return {};
            }
            std::wstring wide(static_cast<size_t>(iwide), L'\0');
            MultiByteToWideChar(
                CP_UTF8, 0, _Utf8.data(), static_cast<int>(_Utf8.size()), wide.data(), iwide);
            return wide;
        }

        // The answer for `_Text`, with COM already started on this thread.
        std::optional<bool> Check(const std::wstring& _Text)
        {
            std::optional<bool> oanswer;
            ISpellCheckerFactory* pfactory = nullptr;
            if (FAILED(CoCreateInstance(__uuidof(SpellCheckerFactory), nullptr,
                    CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&pfactory))))
            {
                return oanswer;
            }
            BOOL bsupported = FALSE;
            ISpellChecker* pchecker = nullptr;
            if (SUCCEEDED(pfactory->IsSupported(kLanguage, &bsupported)) && bsupported
                && SUCCEEDED(pfactory->CreateSpellChecker(kLanguage, &pchecker)))
            {
                IEnumSpellingError* perrors = nullptr;
                if (SUCCEEDED(pchecker->Check(_Text.c_str(), &perrors)))
                {
                    // S_OK hands back an error, S_FALSE means there are none.
                    ISpellingError* perror = nullptr;
                    const HRESULT hrnext = perrors->Next(&perror);
                    if (hrnext == S_OK)
                    {
                        oanswer = false;
                        perror->Release();
                    }
                    else if (hrnext == S_FALSE)
                    {
                        oanswer = true;
                    }
                    perrors->Release();
                }
                pchecker->Release();
            }
            pfactory->Release();
            return oanswer;
        }
    } // namespace

    std::optional<bool> IsDictionaryWord(const std::string& _Text)
    {
        const std::wstring text = Widen(_Text);
        if (text.find_first_not_of(L" \t\r\n") == std::wstring::npos)
        {
            return std::nullopt;
        }
        // S_FALSE (COM already started here) also needs the matching
        // CoUninitialize; a thread in the other apartment model fails with
        // RPC_E_CHANGED_MODE but can still use COM.
        const HRESULT hrinit = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
        if (FAILED(hrinit) && hrinit != RPC_E_CHANGED_MODE)
        {
            return std::nullopt;
        }
        const std::optional<bool> oanswer = Check(text);
        if (SUCCEEDED(hrinit))
        {
            CoUninitialize();
        }
        return oanswer;
    }

#else

    std::optional<bool> IsDictionaryWord(const std::string&)
    {
        return std::nullopt;
    }

#endif

} // namespace gitgud::platform
