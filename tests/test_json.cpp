// Tests for app/Json: parsing, reading, building, and writing JSON; and the
// conversions between JSON and Lua values in the bindings.

#include <catch2/catch_test_macros.hpp>
#include <catch2/matchers/catch_matchers_string.hpp>

extern "C"
{
#include <lua.h>
}

#include "app/Json.h"
#include "lua/LuaEngine.h"

#include <cstdint>
#include <limits>
#include <string>

using namespace gitgud::app;

namespace
{

    Json ParseOk(const std::string& _Text)
    {
        std::string error;
        std::optional<Json> value = Json::Parse(_Text, &error);
        INFO(_Text << " -> " << error);
        REQUIRE(value.has_value());
        return *value;
    }

    std::string ParseError(const std::string& _Text)
    {
        std::string error;
        INFO(_Text);
        REQUIRE_FALSE(Json::Parse(_Text, &error).has_value());
        return error;
    }

} // namespace

TEST_CASE("scalars parse", "[json]")
{
    CHECK(ParseOk("null").IsNull());
    CHECK(ParseOk("true").AsBool() == true);
    CHECK(ParseOk(" false ").AsBool(true) == false);
    CHECK(ParseOk("\"hi\"").AsString() == "hi");
    CHECK(ParseOk("0").AsInt() == 0);
    CHECK(ParseOk("-12").AsInt() == -12);
    CHECK(ParseOk("3.5").AsNumber() == 3.5);
    CHECK(ParseOk("-0.25e2").AsNumber() == -25.0);
    CHECK(ParseOk("1E3").AsNumber() == 1000.0);
}

TEST_CASE("large integers keep their exact value", "[json]")
{
    const Json big = ParseOk("9007199254740993"); // 2^53 + 1: not exact as a double
    CHECK(big.AsInt() == 9007199254740993LL);
    CHECK(big.Dump() == "9007199254740993");

    const Json most = ParseOk("-9223372036854775808");
    CHECK(most.AsInt() == std::numeric_limits<int64_t>::min());

    // Beyond int64: a double only.
    const Json huge = ParseOk("18446744073709551616");
    CHECK(huge.AsNumber() == 18446744073709551616.0);
    CHECK(huge.AsInt(-1) == -1);
}

TEST_CASE("strings decode escapes to UTF-8", "[json]")
{
    CHECK(ParseOk(R"("a\"b\\c\/d")").AsString() == "a\"b\\c/d");
    CHECK(ParseOk(R"("\b\f\n\r\t")").AsString() == "\b\f\n\r\t");
    CHECK(ParseOk(R"("\u00e9")").AsString() == "\xC3\xA9");             // e-acute
    CHECK(ParseOk(R"("\u20AC")").AsString() == "\xE2\x82\xAC");          // euro sign
    CHECK(ParseOk(R"("\ud83c\udf3b")").AsString() == "\xF0\x9F\x8C\xBB"); // sunflower emoji
    CHECK(ParseOk("\"caf\xC3\xA9\"").AsString() == "caf\xC3\xA9");     // raw UTF-8 passes through

    // A lone surrogate becomes U+FFFD rather than invalid UTF-8.
    CHECK(ParseOk(R"("\ud83c")").AsString() == "\xEF\xBF\xBD");
    CHECK(ParseOk(R"("\udf3bx")").AsString() == "\xEF\xBF\xBDx");
}

TEST_CASE("arrays and objects parse and read safely", "[json]")
{
    const Json event = ParseOk(R"({
        "type": "assistant",
        "message": { "content": [ { "type": "text", "text": "Hello" }, { "type": "tool_use", "id": "t1" } ] },
        "session_id": "abc",
        "cost": 0.0125,
        "empty": [], "nothing": {}
    })");

    CHECK(event.IsObject());
    CHECK(event["type"].AsString() == "assistant");
    const Json& content = event["message"]["content"];
    REQUIRE(content.Size() == 2);
    CHECK(content[0]["text"].AsString() == "Hello");
    CHECK(content[1]["id"].AsString() == "t1");
    CHECK(event["cost"].AsNumber() == 0.0125);
    CHECK(event["empty"].IsArray());
    CHECK(event["empty"].Size() == 0);
    CHECK(event["nothing"].IsObject());

    // Missing keys, out-of-range indexes, and wrong types read as null or the fallback.
    CHECK(event["missing"].IsNull());
    CHECK(event["missing"]["deeper"][3].IsNull());
    CHECK(content[7].IsNull());
    CHECK(event["type"].AsInt(42) == 42);
    CHECK(event["cost"].AsString().empty());
    CHECK(event["cost"].AsString("n/a") == "n/a");
    CHECK(event.Has("session_id"));
    CHECK_FALSE(event.Has("sessionId"));

    // Keys keep their order.
    REQUIRE(event.Keys().size() == 6);
    CHECK(event.Keys()[0] == "type");
    CHECK(event.Keys()[5] == "nothing");
}

TEST_CASE("a repeated key keeps the last value", "[json]")
{
    const Json value = ParseOk(R"({"a":1,"b":2,"a":3})");
    CHECK(value.Size() == 2);
    CHECK(value["a"].AsInt() == 3);
}

TEST_CASE("bad input is refused with a position", "[json]")
{
    using Catch::Matchers::ContainsSubstring;

    CHECK_THAT(ParseError(""), ContainsSubstring("unexpected end"));
    CHECK_THAT(ParseError("[1,2,]"), ContainsSubstring("expected a value"));
    CHECK_THAT(ParseError("{\"a\" 1}"), ContainsSubstring("expected ':'"));
    CHECK_THAT(ParseError("{a:1}"), ContainsSubstring("expected a key"));
    CHECK_THAT(ParseError("[1 2]"), ContainsSubstring("expected ',' or ']'"));
    CHECK_THAT(ParseError("\"open"), ContainsSubstring("unterminated"));
    CHECK_THAT(ParseError("\"tab\there\""), ContainsSubstring("control character"));
    CHECK_THAT(ParseError(R"("\q")"), ContainsSubstring("bad escape"));
    CHECK_THAT(ParseError(R"("\u12")"), ContainsSubstring("\\u escape"));
    CHECK_THAT(ParseError("01"), ContainsSubstring("after the value"));
    CHECK_THAT(ParseError("1."), ContainsSubstring("decimal point"));
    CHECK_THAT(ParseError("-"), ContainsSubstring("digit"));
    CHECK_THAT(ParseError("1e"), ContainsSubstring("exponent"));
    CHECK_THAT(ParseError("tru"), ContainsSubstring("expected a value"));
    CHECK_THAT(ParseError("nul"), ContainsSubstring("expected a value"));
    CHECK_THAT(ParseError("{} {}"), ContainsSubstring("after the value"));
    CHECK_THAT(ParseError("[1,2,]"), ContainsSubstring("at offset 5"));
}

TEST_CASE("deep nesting is refused, not a crash", "[json]")
{
    const std::string deep = std::string(100000, '[') + std::string(100000, ']');
    CHECK_THAT(ParseError(deep), Catch::Matchers::ContainsSubstring("nested too deeply"));

    const std::string fine = std::string(200, '[') + std::string(200, ']');
    CHECK(ParseOk(fine).IsArray());
}

TEST_CASE("values build and dump compactly", "[json]")
{
    Json request = Json::Object();
    request.Set("type", "user");
    request.Set("count", 3);
    request.Set("size", static_cast<size_t>(7));
    request.Set("ratio", 0.5);
    request.Set("ok", true);
    request.Set("none", nullptr);
    request.Set("list", Json::Array().Push("a").Push(1).Push(Json::Object()));
    request.At("nested").Set("deep", "x");
    request.Set("count", 4); // replaces in place, keeps the position

    CHECK(request.Dump() ==
          R"({"type":"user","count":4,"size":7,"ratio":0.5,"ok":true,"none":null,"list":["a",1,{}],"nested":{"deep":"x"}})");

    // A null becomes an array or an object on first use.
    Json list;
    list.Push(1).Push(2);
    CHECK(list.Dump() == "[1,2]");
    Json object;
    object.Set("k", "v");
    CHECK(object.Dump() == R"({"k":"v"})");

    // Set on a non-object changes nothing.
    Json text("hello");
    text.Set("k", 1);
    CHECK(text.Dump() == R"("hello")");
}

TEST_CASE("strings and numbers are written so they read back", "[json]")
{
    CHECK(JsonQuote("say \"hi\"\\\n") == R"("say \"hi\"\\\n")");
    CHECK(JsonQuote(std::string("\x01\x1F", 2)) == R"("\u0001\u001f")");
    CHECK(JsonQuote("caf\xC3\xA9") == "\"caf\xC3\xA9\"");

    CHECK(Json(0.1).Dump() == "0.1");
    CHECK(Json(-2.5e-8).Dump() == "-2.5e-08");
    CHECK(Json(std::numeric_limits<double>::infinity()).Dump() == "null");
    CHECK(Json(std::numeric_limits<double>::quiet_NaN()).Dump() == "null");

    const std::string text =
        R"({"a":[1,-2,3.25,true,false,null,"x\ty"],"b":{"c":"\u00e9\ud83c\udf3b"},"d":9007199254740993})";
    const Json first = ParseOk(text);
    const Json second = ParseOk(first.Dump());
    CHECK(first == second);
    CHECK(second["d"].AsInt() == 9007199254740993LL);
}

TEST_CASE("equality ignores key order", "[json]")
{
    CHECK(ParseOk(R"({"a":1,"b":[2,3]})") == ParseOk(R"({"b":[2,3],"a":1})"));
    CHECK(ParseOk(R"({"a":1})") != ParseOk(R"({"a":2})"));
    CHECK(ParseOk(R"([1,2])") != ParseOk(R"([2,1])"));
    CHECK(ParseOk("1") == ParseOk("1.0"));
}

TEST_CASE("Scripts convert between JSON and Lua values", "[json][lua]")
{
    gitgud::lua::LuaEngine engine;
    REQUIRE(engine.Initialize());
    lua_State* pL = engine.State();

    const char* kScript = R"(
        local v = gitgud.jsonDecode('{"a":[1,2.5,"x",true],"b":{"c":null},"n":-3}')
        assert(v.a[1] == 1 and math.type(v.a[1]) == "integer")
        assert(v.a[2] == 2.5 and v.a[3] == "x" and v.a[4] == true)
        assert(type(v.b) == "table" and v.b.c == nil and v.n == -3)
        local bad, msg = gitgud.jsonDecode('{"a":')
        assert(bad == nil and type(msg) == "string")

        assert(gitgud.jsonEncode({1, 2, "three"}) == '[1,2,"three"]')
        assert(gitgud.jsonEncode({}) == '{}')
        assert(gitgud.jsonEncode({name = "x"}) == '{"name":"x"}')
        assert(gitgud.jsonEncode("q\"") == '"q\\""')
        assert(gitgud.jsonEncode(1.5) == '1.5')
        local back = gitgud.jsonDecode(gitgud.jsonEncode({list = {1, {k = false}}}))
        assert(back.list[2].k == false)

        local t = {}
        t.self = t
        local none, why = gitgud.jsonEncode(t)
        assert(none == nil and why:find("deep"))
        assert(gitgud.jsonEncode({[1] = 1, [3] = 3}) == nil)
        assert(gitgud.jsonEncode(print) == nil)
        assert(gitgud.jsonDecode(string.rep("[", 200) .. string.rep("]", 200)) == nil)
        assert(#gitgud.jsonDecode(string.rep("[", 30) .. "7" .. string.rep("]", 30)) == 1)
        ok = true
    )";
    REQUIRE(engine.Eval(kScript));
    lua_getglobal(pL, "ok");
    CHECK(lua_toboolean(pL, -1));
    lua_pop(pL, 1);
}
