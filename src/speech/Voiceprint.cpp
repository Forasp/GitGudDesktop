#include "speech/Voiceprint.h"

#include "app/Json.h"
#include "platform/Shell.h"

#include <filesystem>
#include <fstream>
#include <sstream>

namespace gitgud::speech
{

    namespace fs = std::filesystem;
    using app::Json;

    bool LoadVoiceprint(const std::string& _Path, Voiceprint& _Out)
    {
        if (_Path.empty())
        {
            return false;
        }
        std::ifstream file(fs::u8path(_Path), std::ios::binary);
        if (!file)
        {
            return false;
        }
        std::stringstream ss;
        ss << file.rdbuf();
        const std::optional<Json> parsed = Json::Parse(ss.str());
        if (!parsed || !parsed->IsObject() || !(*parsed)["vector"].IsArray())
        {
            return false;
        }
        Voiceprint print;
        print.m_Model = (*parsed)["model"].AsString();
        print.m_fSeconds = (*parsed)["seconds"].AsNumber();
        print.m_iSamples = static_cast<int>((*parsed)["samples"].AsNumber());
        for (const Json& value : (*parsed)["vector"].Items())
        {
            print.m_Vector.push_back(static_cast<float>(value.AsNumber()));
        }
        if (print.m_Vector.empty())
        {
            return false;
        }
        _Out = std::move(print);
        return true;
    }

    bool SaveVoiceprint(const std::string& _Path, const Voiceprint& _Print, std::string& _Error)
    {
        if (_Path.empty())
        {
            _Error = "no voiceprint file";
            return false;
        }
        Json json = Json::Object();
        json.Set("model", _Print.m_Model);
        json.Set("seconds", _Print.m_fSeconds);
        json.Set("samples", _Print.m_iSamples);
        Json vector = Json::Array();
        for (float x : _Print.m_Vector)
        {
            vector.Push(static_cast<double>(x));
        }
        json.Set("vector", std::move(vector));
        return platform::WriteFileAtomically(_Path, json.Dump(), _Error);
    }

    bool RemoveVoiceprint(const std::string& _Path)
    {
        std::error_code ec;
        return !_Path.empty() && fs::remove(fs::u8path(_Path), ec);
    }

    float Similarity(const std::vector<float>& _A, const std::vector<float>& _B)
    {
        if (_A.size() != _B.size() || _A.empty())
        {
            return -1;
        }
        double fsum = 0;
        for (std::size_t ni = 0; ni < _A.size(); ++ni)
        {
            fsum += static_cast<double>(_A[ni]) * _B[ni];
        }
        return static_cast<float>(fsum);
    }

} // namespace gitgud::speech
