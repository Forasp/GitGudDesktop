// WordPiece (src/speech): BERT's uncased tokenizer for the turn-taking
// model, on a small vocabulary, and the classifier's pair of texts made of
// it. The real vocabulary's answers are checked against the reference
// tokenizer in test_speech.cpp ([.voice-decider]).

#include <catch2/catch_test_macros.hpp>

#include "speech/TextClassifier.h"
#include "speech/WordPiece.h"

#include <chrono>
#include <filesystem>
#include <fstream>
#include <functional>
#include <random>
#include <string>
#include <vector>

using gitgud::speech::TextClassifier;
using gitgud::speech::WordPiece;
namespace fs = std::filesystem;

namespace
{
    // Line n is id n.
    const char* const kVocab = "[PAD]\n[UNK]\n[CLS]\n[SEP]\nhello\nworld\nun\n##believ\n##able\n"
                               "cafe\n,\n.\n?\n'\ns\nit\n0\n7\n|\npause\n";

    WordPiece Loaded()
    {
        WordPiece tokenizer;
        std::string error;
        REQUIRE(tokenizer.Load(kVocab, error));
        return tokenizer;
    }
} // namespace

TEST_CASE("WordPiece needs a vocabulary with its special pieces", "[wordpiece]")
{
    WordPiece tokenizer;
    std::string error;
    CHECK_FALSE(tokenizer.Load("hello\nworld\n", error));
    CHECK_FALSE(error.empty());
    CHECK_FALSE(tokenizer.Loaded());

    const WordPiece loaded = Loaded();
    CHECK(loaded.Loaded());
    CHECK(loaded.Cls() == 2);
    CHECK(loaded.Sep() == 3);
    CHECK(loaded.Unk() == 1);

    WordPiece crlf;
    REQUIRE(crlf.Load("[PAD]\r\n[UNK]\r\n[CLS]\r\n[SEP]\r\nhello\r\n", error));
    CHECK(crlf.Encode("hello") == std::vector<int64_t>{4});
}

TEST_CASE("WordPiece splits words as BERT does", "[wordpiece]")
{
    // Lowercase, accents off, punctuation on its own, spaces and control
    // characters gone.
    CHECK(
        WordPiece::Words("Hello, WORLD.") == std::vector<std::string>{"hello", ",", "world", "."});
    CHECK(WordPiece::Words("Café  naïve\tÅngström\nŁódź") ==
          std::vector<std::string>{"cafe", "naive", "angstrom", "łodz"});
    CHECK(WordPiece::Words("it's 0.7 s | pause") ==
          std::vector<std::string>{"it", "'", "s", "0", ".", "7", "s", "|", "pause"});
    CHECK(WordPiece::Words("zero\xE2\x80\x8Bwidth soft\xC2\xADhyphen") ==
          std::vector<std::string>{"zerowidth", "softhyphen"});
    CHECK(WordPiece::Words("\xE2\x80\x9Cquoted\xE2\x80\x9D \xE2\x80\x94 so\xE2\x80\xA6") ==
          std::vector<std::string>{
              "\xE2\x80\x9C", "quoted", "\xE2\x80\x9D", "\xE2\x80\x94", "so", "\xE2\x80\xA6"});
    CHECK(WordPiece::Words("").empty());
}

TEST_CASE("WordPiece takes the longest pieces, or [UNK] for the whole word", "[wordpiece]")
{
    const WordPiece tokenizer = Loaded();
    CHECK(tokenizer.Encode("Hello, world.") == std::vector<int64_t>{4, 10, 5, 11});
    CHECK(tokenizer.Encode("Unbelievable?") == std::vector<int64_t>{6, 7, 8, 12});
    CHECK(tokenizer.Encode("café") == std::vector<int64_t>{9});
    // A word with a part the vocabulary lacks is [UNK], whole.
    CHECK(tokenizer.Encode("unbelievably hello") == std::vector<int64_t>{1, 4});
    // Longer than 100 characters: [UNK] without trying.
    CHECK(tokenizer.Encode(std::string(101, 's')) == std::vector<int64_t>{1});
    CHECK(tokenizer.Encode("it's 0.7 | pause") ==
          std::vector<int64_t>{15, 13, 14, 16, 11, 17, 18, 19});
}

TEST_CASE("TextClassifier's pair keeps the first text's start, the second's end", "[wordpiece]")
{
    // The vocabulary loads before the graph: without one, Load fails after
    // the tokenizer is ready, and nothing of ONNX Runtime's is touched.
    const fs::path dir =
        fs::temp_directory_path() / ("gitgud_wordpiece_" + std::to_string(std::random_device()()));
    fs::create_directories(dir);
    {
        std::ofstream(dir / "vocab.txt", std::ios::binary) << kVocab;
    }
    {
        TextClassifier classifier((dir / "missing.onnx").u8string(),
            (dir / "vocab.txt").u8string(), 1,
            [](const char*, std::chrono::milliseconds, const std::function<void()>& _Call)
            {
                _Call();
                return true;
            });
        std::string error;
        CHECK_FALSE(classifier.Load(error));
        CHECK(error.find("missing") != std::string::npos);

        // Whole when it fits: [CLS] first [SEP] second [SEP].
        CHECK(classifier.Encode("hello", "world", 256, 40) == std::vector<int64_t>{2, 4, 3, 5, 3});
        // `first` cut to firstMax, `second` to the room left, its end kept.
        CHECK(classifier.Encode("hello world hello", "it 0 7 pause", 8, 2) ==
              std::vector<int64_t>{2, 4, 5, 3, 16, 17, 19, 3});
        CHECK(classifier.Encode("hello", "world", 256, 0) == std::vector<int64_t>{2, 3, 5, 3});
        // A first text longer than maxLength allows is cut to fit too.
        CHECK(classifier.Encode("hello world hello world", "it", 5, 40) ==
              std::vector<int64_t>{2, 4, 5, 3, 3});
        CHECK(classifier.Encode("hello world", "it", 0, 40) == std::vector<int64_t>{2, 3, 3});
    }
    std::error_code ec;
    fs::remove_all(dir, ec);
}
