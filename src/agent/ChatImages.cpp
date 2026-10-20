#include "agent/ChatImages.h"

#include "app/Profiler.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <mutex>
#include <unordered_map>

#include "imaging/ChatImage.h"
#include "platform/Shell.h"

namespace gitgud::agent
{

    using app::Json;

    namespace
    {

        namespace fs = std::filesystem;

        // Two events can carry the same picture at once.
        std::mutex g_WriteMutex;

        std::string NameOf(const std::string& _Bytes, const std::string& _MediaType)
        {
            std::uint64_t uhash = 14695981039346656037ull; // FNV-1a
            for (const char c : _Bytes)
            {
                uhash = (uhash ^ static_cast<unsigned char>(c)) * 1099511628211ull;
            }
            char sz[48];
            std::snprintf(sz, sizeof(sz), "%016llx-%zx.", static_cast<unsigned long long>(uhash),
                _Bytes.size());
            return sz + imaging::ExtensionOf(_MediaType);
        }

        bool IsBase64Image(const Json& _Block)
        {
            return _Block.IsObject() && _Block["type"].AsString() == "image" &&
                   _Block["source"]["type"].AsString() == "base64";
        }

        // Pictures already stored, by their base64 text: a transcript is read
        // again and again (opening it, the recap, rewind), and decoding and
        // hashing every screenshot in it each time made each read slow.
        // Keyed by the text's length and a hash of 64 slices of it; the
        // file is checked for before it's trusted.
        std::mutex g_KnownMutex;
        std::unordered_map<std::string, std::string> g_Known;

        std::string KnownKey(const std::string& _Data)
        {
            std::uint64_t uhash = 14695981039346656037ull;
            const std::size_t nslices = 64;
            const std::size_t nslice = 64;
            const std::size_t nstep = _Data.size() / nslices + 1;
            for (std::size_t i = 0; i < _Data.size(); i += nstep)
            {
                const std::size_t nend = std::min(_Data.size(), i + nslice);
                for (std::size_t j = i; j < nend; ++j)
                {
                    uhash = (uhash ^ static_cast<unsigned char>(_Data[j])) * 1099511628211ull;
                }
            }
            for (std::size_t j = _Data.size() > nslice ? _Data.size() - nslice : 0; j < _Data.size(); ++j)
            {
                uhash = (uhash ^ static_cast<unsigned char>(_Data[j])) * 1099511628211ull;
            }
            char sz[48];
            std::snprintf(sz, sizeof(sz), "%016llx-%zx", static_cast<unsigned long long>(uhash), _Data.size());
            return sz;
        }

        std::string StoreBlock(const Json& _Block)
        {
            const std::string& data = _Block["source"]["data"].AsString();
            const std::string key = ChatImageDirectory() + "|" + KnownKey(data);
            {
                std::lock_guard<std::mutex> lock(g_KnownMutex);
                const auto it = g_Known.find(key);
                std::error_code ec;
                if (it != g_Known.end() && fs::is_regular_file(fs::u8path(it->second), ec))
                {
                    return it->second;
                }
            }
            std::string bytes;
            if (!imaging::Base64Decode(data, bytes) || bytes.empty())
            {
                return {};
            }
            std::string type = imaging::SniffMediaType(bytes);
            if (type.empty())
            {
                type = _Block["source"]["media_type"].AsString();
            }
            std::string path = StoreChatImage(bytes, type);
            if (!path.empty())
            {
                std::lock_guard<std::mutex> lock(g_KnownMutex);
                g_Known[key] = path;
            }
            return path;
        }

    } // namespace

    std::string ChatImageDirectory()
    {
        return (fs::u8path(platform::LocalDataDirectory()) / "chat-images").u8string();
    }

    std::string StoreChatImage(const std::string& _Bytes, const std::string& _MediaType)
    {
        GITGUD_PROFILE_FUNCTION();
        if (_Bytes.empty())
        {
            return {};
        }
        const fs::path dir = fs::u8path(ChatImageDirectory());
        const fs::path path = dir / fs::u8path(NameOf(_Bytes, _MediaType));
        std::lock_guard<std::mutex> lock(g_WriteMutex);
        std::error_code ec;
        if (fs::is_regular_file(path, ec))
        {
            return path.u8string();
        }
        fs::create_directories(dir, ec);
        std::string error;
        if (!platform::WriteFileAtomically(path.u8string(), _Bytes, error))
        {
            return {};
        }
        return path.u8string();
    }

    std::vector<std::string> TakeChatImages(Json& _Content)
    {
        GITGUD_PROFILE_FUNCTION();
        std::vector<std::string> paths;
        if (!_Content.IsArray())
        {
            return paths;
        }
        bool bany = false;
        for (const Json& block : _Content.Items())
        {
            bany = bany || IsBase64Image(block);
        }
        if (!bany)
        {
            return paths;
        }
        Json out = Json::Array();
        for (const Json& block : _Content.Items())
        {
            if (!IsBase64Image(block))
            {
                out.Push(block);
                continue;
            }
            const std::string path = StoreBlock(block);
            if (!path.empty())
            {
                paths.push_back(path);
            }
            out.Push(Json::Object().Set("type", "image").Set("path", path));
        }
        _Content = std::move(out);
        return paths;
    }

    std::vector<std::string> ChatImagesIn(const Json& _Content)
    {
        GITGUD_PROFILE_FUNCTION();
        std::vector<std::string> paths;
        if (!_Content.IsArray())
        {
            return paths;
        }
        for (const Json& block : _Content.Items())
        {
            if (IsBase64Image(block))
            {
                const std::string path = StoreBlock(block);
                if (!path.empty())
                {
                    paths.push_back(path);
                }
            }
        }
        return paths;
    }

    Json ImageBlockFromFile(const std::string& _Path, std::string& _Error)
    {
        GITGUD_PROFILE_FUNCTION();
        std::ifstream in(fs::u8path(_Path), std::ios::binary);
        if (!in)
        {
            _Error = "couldn't read " + _Path;
            return Json();
        }
        const std::string bytes((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        std::string type;
        std::string prepared;
        if (!imaging::PrepareForModel(bytes, type, prepared, _Error))
        {
            return Json();
        }
        return Json::Object()
            .Set("type", "image")
            .Set("source", Json::Object()
                               .Set("type", "base64")
                               .Set("media_type", type)
                               .Set("data", imaging::Base64Encode(prepared)));
    }

} // namespace gitgud::agent
