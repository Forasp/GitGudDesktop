// Pictures in a conversation: imaging/ChatImage.h (sniffing, base64,
// scaling down for the model) and agent/ChatImages.h (stored as files,
// in the stream and in transcripts).

#include <catch2/catch_test_macros.hpp>

#include "agent/ChatImages.h"
#include "agent/ClaudeSession.h"
#include "agent/ClaudeTranscripts.h"
#include "imaging/ChatImage.h"

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

using gitgud::agent::ClaudeSession;
using gitgud::agent::ClaudeTranscripts;
using gitgud::app::Json;
namespace imaging = gitgud::imaging;
namespace fs = std::filesystem;

namespace
{

    void SetEnv(const char* _szName, const std::string& _Value)
    {
#if defined(_WIN32)
        _putenv_s(_szName, _Value.c_str());
#else
        setenv(_szName, _Value.c_str(), 1);
#endif
    }

    // The local data folder (where chat-images/ goes) and Claude Code's config
    // folder in a scratch folder, for the test's lifetime.
    struct ScratchData
    {
        fs::path m_Root;
        std::string m_OldLocal;
        std::string m_OldXdg;

        ScratchData()
        {
            m_Root = fs::temp_directory_path() / "gitgud-chat-images";
            fs::remove_all(m_Root);
            fs::create_directories(m_Root / "claude");
            const char* szlocal = std::getenv("LOCALAPPDATA");
            m_OldLocal = szlocal ? szlocal : "";
            const char* szxdg = std::getenv("XDG_DATA_HOME");
            m_OldXdg = szxdg ? szxdg : "";
            SetEnv("LOCALAPPDATA", m_Root.u8string());
            SetEnv("XDG_DATA_HOME", m_Root.u8string());
            SetEnv("CLAUDE_CONFIG_DIR", (m_Root / "claude").u8string());
        }

        ~ScratchData()
        {
            SetEnv("LOCALAPPDATA", m_OldLocal);
            SetEnv("XDG_DATA_HOME", m_OldXdg);
            SetEnv("CLAUDE_CONFIG_DIR", "");
            std::error_code ec;
            fs::remove_all(m_Root, ec);
        }
    };

    imaging::Image Gradient(int _iWidth, int _iHeight)
    {
        imaging::Image img;
        img.m_iWidth = _iWidth;
        img.m_iHeight = _iHeight;
        img.m_Rgba.resize(static_cast<std::size_t>(_iWidth) * _iHeight * 4);
        for (int y = 0; y < _iHeight; ++y)
        {
            for (int x = 0; x < _iWidth; ++x)
            {
                std::uint8_t* p = &img.m_Rgba[(static_cast<std::size_t>(y) * _iWidth + x) * 4];
                p[0] = static_cast<std::uint8_t>(x * 255 / _iWidth);
                p[1] = static_cast<std::uint8_t>(y * 255 / _iHeight);
                p[2] = static_cast<std::uint8_t>((x * 7 + y * 13) & 0xFF); // noise: PNG won't shrink it away
                p[3] = 255;
            }
        }
        return img;
    }

    std::string Png(int _iWidth, int _iHeight)
    {
        std::string bytes;
        REQUIRE(imaging::EncodePng(Gradient(_iWidth, _iHeight), bytes));
        return bytes;
    }

    std::string ReadFile(const std::string& _Path)
    {
        std::ifstream in(fs::u8path(_Path), std::ios::binary);
        return std::string((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    }

} // namespace

TEST_CASE("Chat images: types, base64, sizes", "[agent][images]")
{
    const std::string png = Png(40, 30);
    CHECK(imaging::SniffMediaType(png) == "image/png");
    CHECK(imaging::SniffMediaType("\xff\xd8\xff\xe0rest") == "image/jpeg");
    CHECK(imaging::SniffMediaType("GIF89a...") == "image/gif");
    CHECK(imaging::SniffMediaType(std::string("RIFF\0\0\0\0WEBPVP8 ", 16)) == "image/webp");
    CHECK(imaging::SniffMediaType("hello").empty());
    CHECK(imaging::ExtensionOf("image/jpeg") == "jpg");
    CHECK(imaging::ExtensionOf("image/png") == "png");

    for (const std::string& sample : {std::string(), std::string("a"), std::string("ab"),
             std::string("abc"), std::string("abcd"), png})
    {
        std::string back;
        REQUIRE(imaging::Base64Decode(imaging::Base64Encode(sample), back));
        CHECK(back == sample);
    }
    CHECK(imaging::Base64Encode("Man") == "TWFu");
    CHECK(imaging::Base64Encode("Ma") == "TWE=");

    int iwidth = 0;
    int iheight = 0;
    REQUIRE(imaging::ReadSize(png, iwidth, iheight));
    CHECK(iwidth == 40);
    CHECK(iheight == 30);

    const imaging::Image fitted = imaging::Fit(Gradient(400, 100), 200, 200);
    CHECK(fitted.m_iWidth == 200);
    CHECK(fitted.m_iHeight == 50);
    CHECK(imaging::Fit(Gradient(10, 10), 200, 200).m_iWidth == 10); // never up
}

TEST_CASE("Chat images: prepared for the model", "[agent][images]")
{
    std::string type;
    std::string out;
    std::string error;

    // Within the limits: as it is.
    const std::string small = Png(64, 48);
    REQUIRE(imaging::PrepareForModel(small, type, out, error));
    CHECK(type == "image/png");
    CHECK(out == small);

    // Too wide: scaled down to the long edge.
    REQUIRE(imaging::PrepareForModel(Png(3000, 1000), type, out, error));
    int iwidth = 0;
    int iheight = 0;
    REQUIRE(imaging::ReadSize(out, iwidth, iheight));
    CHECK(iwidth == imaging::kMaxModelEdge);
    CHECK(iheight == 523);
    CHECK(out.size() <= imaging::kMaxModelBytes);

    CHECK_FALSE(imaging::PrepareForModel("not an image", type, out, error));
    CHECK_FALSE(error.empty());
}

TEST_CASE("Chat images: stored once, by content", "[agent][images]")
{
    ScratchData scratch;
    const std::string png = Png(8, 6);
    const std::string path = gitgud::agent::StoreChatImage(png, "image/png");
    REQUIRE_FALSE(path.empty());
    CHECK(fs::u8path(path).parent_path() == fs::u8path(gitgud::agent::ChatImageDirectory()));
    CHECK(fs::u8path(path).extension() == ".png");
    CHECK(ReadFile(path) == png);
    CHECK(gitgud::agent::StoreChatImage(png, "image/png") == path);
    CHECK(gitgud::agent::StoreChatImage(Png(9, 6), "image/png") != path);

    // Base64 blocks become paths; other blocks stay.
    Json content = Json::Array()
                       .Push(Json::Object().Set("type", "text").Set("text", "see"))
                       .Push(Json::Object()
                               .Set("type", "image")
                               .Set("source", Json::Object()
                                                  .Set("type", "base64")
                                                  .Set("media_type", "image/png")
                                                  .Set("data", imaging::Base64Encode(png))));
    CHECK(gitgud::agent::ChatImagesIn(content) == std::vector<std::string>{path});
    const auto taken = gitgud::agent::TakeChatImages(content);
    REQUIRE(taken.size() == 1);
    CHECK(taken[0] == path);
    CHECK(content[0]["text"].AsString() == "see");
    CHECK(content[1]["type"].AsString() == "image");
    CHECK(content[1]["path"].AsString() == path);
    CHECK_FALSE(content[1].Has("source"));

    Json text("just text");
    CHECK(gitgud::agent::TakeChatImages(text).empty());
    CHECK(text.AsString() == "just text");

    // A file as a block for a user message.
    std::string error;
    const Json block = gitgud::agent::ImageBlockFromFile(path, error);
    REQUIRE_FALSE(block.IsNull());
    CHECK(block["source"]["media_type"].AsString() == "image/png");
    CHECK(block["source"]["data"].AsString() == imaging::Base64Encode(png));
    CHECK(gitgud::agent::ImageBlockFromFile((scratch.m_Root / "missing.png").u8string(), error).IsNull());
}

TEST_CASE("Chat images: sent before the text, shown from tool results", "[agent][images]")
{
    ScratchData scratch;
    std::vector<Json> written;
    std::vector<Json> results;
    ClaudeSession session(
        [&](const std::string& _Line)
        {
            written.push_back(Json::Parse(_Line).value_or(Json()));
            return true;
        },
        [&](const std::string& _Type, const Json& _Detail)
        {
            if (_Type == "toolResult")
            {
                results.push_back(_Detail);
            }
        });

    const std::string png = Png(8, 6);
    const Json image = Json::Object().Set("type", "image").Set("source",
        Json::Object().Set("type", "base64").Set("media_type", "image/png").Set("data", imaging::Base64Encode(png)));
    REQUIRE(session.Send("what's this?", {image}));
    REQUIRE(written.size() == 1);
    const Json& content = written[0]["message"]["content"];
    REQUIRE(content.IsArray());
    REQUIRE(content.Size() == 2);
    CHECK(content[0]["type"].AsString() == "image");
    CHECK(content[1]["text"].AsString() == "what's this?");

    REQUIRE(session.Send("plain"));
    CHECK(written[1]["message"]["content"].AsString() == "plain");

    session.HandleLine(
        Json::Object()
            .Set("type", "user")
            .Set("message", Json::Object().Set("content", Json::Array().Push(Json::Object()
                    .Set("type", "tool_result")
                    .Set("tool_use_id", "toolu_1")
                    .Set("content", Json::Array().Push(image))
                    .Set("is_error", false))))
            .Set("parent_tool_use_id", nullptr)
            .Dump());
    REQUIRE(results.size() == 1);
    REQUIRE(results[0]["images"].Size() == 1);
    const std::string path = results[0]["images"][0].AsString();
    CHECK(ReadFile(path) == png);
    CHECK(results[0]["content"][0]["path"].AsString() == path);
    CHECK_FALSE(results[0]["content"][0].Has("source")); // no base64 handed on
    CHECK(results[0]["text"].AsString().empty());
}

TEST_CASE("Chat images: a transcript's pictures read back as files", "[agent][images]")
{
    ScratchData scratch;
    const std::string png = Png(8, 6);
    const std::string data = imaging::Base64Encode(png);
    const std::string cwd = "C:\\work\\pictures";
    const fs::path dir = scratch.m_Root / "claude" / "projects" / ClaudeTranscripts::ProjectFolderName(cwd);
    fs::create_directories(dir);
    const std::string image =
        R"({"type":"image","source":{"type":"base64","media_type":"image/png","data":")" + data + R"("}})";
    std::ofstream(dir / "pics-0001.jsonl", std::ios::binary)
        << R"({"type":"user","message":{"role":"user","content":[)" << image
        << R"(,{"type":"text","text":"look at this"}]}})" << "\n"
        << R"({"type":"user","message":{"role":"user","content":[)" << image << R"(]}})" << "\n"
        << R"({"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"a.png"}}]}})"
        << "\n"
        << R"({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":[)"
        << image << R"(],"is_error":false}]}})" << "\n";

    const auto entries = ClaudeTranscripts::Read(cwd, "pics-0001");
    REQUIRE(entries.size() == 4);
    CHECK(entries[0].m_Kind == "user");
    CHECK(entries[0].m_Text == "look at this");
    REQUIRE(entries[0].m_Images.size() == 1);
    CHECK(ReadFile(entries[0].m_Images[0]) == png);
    CHECK(entries[1].m_Kind == "user"); // pictures alone are a message too
    CHECK(entries[1].m_Text.empty());
    CHECK(entries[1].m_Images == entries[0].m_Images);
    CHECK(entries[3].m_Kind == "toolResult");
    CHECK(entries[3].m_Images == entries[0].m_Images);
}
