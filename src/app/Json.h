#pragma once

// -----------------------------------------------------------------------------
// Json: a JSON value, parser, and writer (RFC 8259).
//
// The app speaks JSON to Claude Code (stream-json lines) and to the server's
// REST API. A value is null, a bool, a number, a string, an array, or an
// object; objects keep their keys in insertion order so output is stable.
//
//     std::string error;
//     std::optional<Json> event = Json::Parse(line, &error);
//     if (event && (*event)["type"].AsString() == "result") ...
//
//     Json request = Json::Object();
//     request.Set("type", "user");
//     request.Set("content", Json::Array().Push("hello"));
//     std::string line = request.Dump() + "\n";
//
// Reading never throws: a missing key or index, or the wrong type, gives a
// null value or the fallback. Numbers are doubles; whole numbers that fit in
// 64 bits also keep their exact integer (ids, sizes, timestamps).
// Strings are UTF-8; \u escapes, surrogate pairs included, decode to UTF-8.
// -----------------------------------------------------------------------------

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <type_traits>
#include <vector>

namespace gitgud::app
{

    class Json
    {
      public:
        enum class Type
        {
            Null,
            Bool,
            Number,
            String,
            Array,
            Object,
        };

        Json() = default;
        Json(std::nullptr_t);
        Json(bool _bValue);
        Json(double _fValue);

        // Any integer type (int, int64_t, size_t, ...). Values beyond int64_t
        // keep only their double.
        template <typename T, std::enable_if_t<std::is_integral_v<T> && !std::is_same_v<T, bool>, int> = 0>
        Json(T _Value) : m_Type(Type::Number), m_fNumber(static_cast<double>(_Value))
        {
            if constexpr (std::is_signed_v<T>)
            {
                m_iInteger = static_cast<int64_t>(_Value);
                m_bIsInteger = true;
            }
            else if (static_cast<uint64_t>(_Value) <= static_cast<uint64_t>(INT64_MAX))
            {
                m_iInteger = static_cast<int64_t>(_Value);
                m_bIsInteger = true;
            }
        }
        Json(const char* _szValue);
        Json(std::string _Value);

        static Json Array();
        static Json Object();

        // Parse a whole document (surrounding whitespace allowed). nullopt on
        // bad input, with "<message> at offset <n>" in _pError if given.
        static std::optional<Json> Parse(const std::string& _Text, std::string* _pError = nullptr);

        // Compact text; numbers that aren't finite are written as null.
        std::string Dump() const;

        Type GetType() const
        {
            return m_Type;
        }

        bool IsNull() const
        {
            return m_Type == Type::Null;
        }

        bool IsBool() const
        {
            return m_Type == Type::Bool;
        }

        bool IsNumber() const
        {
            return m_Type == Type::Number;
        }

        bool IsString() const
        {
            return m_Type == Type::String;
        }

        bool IsArray() const
        {
            return m_Type == Type::Array;
        }

        bool IsObject() const
        {
            return m_Type == Type::Object;
        }

        // The value, or _Fallback when it's another type.
        bool AsBool(bool _bFallback = false) const;
        double AsNumber(double _fFallback = 0.0) const;
        int64_t AsInt(int64_t _iFallback = 0) const;
        const std::string& AsString() const; // "" unless a string
        std::string AsString(const std::string& _Fallback) const;

        // Arrays: element count (objects: key count; others 0), an element
        // (null when out of range or not an array), and append (turns a null
        // into an array; returns *this so calls chain).
        size_t Size() const;
        const Json& operator[](size_t _nIndex) const;
        Json& Push(Json _Value);
        const std::vector<Json>& Items() const;

        // Objects: a member (null when missing or not an object), whether one
        // exists, and set (replaces in place, else appends; turns a null into
        // an object; returns *this so calls chain).
        const Json& operator[](const std::string& _Key) const;
        bool Has(const std::string& _Key) const;
        Json& Set(const std::string& _Key, Json _Value);
        const std::vector<std::string>& Keys() const;

        // A mutable member, created (null) when missing; turns a null into an
        // object. On a value that's neither null nor an object, Set and At
        // change nothing (At returns a throwaway value).
        Json& At(const std::string& _Key);

        bool operator==(const Json& _Other) const;

        bool operator!=(const Json& _Other) const
        {
            return !(*this == _Other);
        }

      private:
        void DumpTo(std::string& _Out) const;

        Type m_Type = Type::Null;
        bool m_bValue = false;
        double m_fNumber = 0.0;
        int64_t m_iInteger = 0;
        bool m_bIsInteger = false; // m_iInteger holds the exact value
        std::string m_String;
        std::vector<Json> m_Items;       // array elements, or object values
        std::vector<std::string> m_Keys; // object keys, parallel to m_Items

        friend class JsonParser;
    };

    // Write _Text as a JSON string literal, quotes included.
    std::string JsonQuote(const std::string& _Text);

} // namespace gitgud::app
