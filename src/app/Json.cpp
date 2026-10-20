#include "app/Json.h"

#include "app/Profiler.h"

#include <charconv>
#include <cmath>
#include <limits>

namespace gitgud::app
{

    namespace
    {

        // Deeper nesting than this is refused rather than risking the stack.
        constexpr int kMaxDepth = 512;

        const Json& NullValue()
        {
            static const Json knull;
            return knull;
        }

        void AppendUtf8(std::string& _Out, uint32_t _uCodePoint)
        {
            if (_uCodePoint < 0x80)
            {
                _Out += static_cast<char>(_uCodePoint);
            }
            else if (_uCodePoint < 0x800)
            {
                _Out += static_cast<char>(0xC0 | (_uCodePoint >> 6));
                _Out += static_cast<char>(0x80 | (_uCodePoint & 0x3F));
            }
            else if (_uCodePoint < 0x10000)
            {
                _Out += static_cast<char>(0xE0 | (_uCodePoint >> 12));
                _Out += static_cast<char>(0x80 | ((_uCodePoint >> 6) & 0x3F));
                _Out += static_cast<char>(0x80 | (_uCodePoint & 0x3F));
            }
            else
            {
                _Out += static_cast<char>(0xF0 | (_uCodePoint >> 18));
                _Out += static_cast<char>(0x80 | ((_uCodePoint >> 12) & 0x3F));
                _Out += static_cast<char>(0x80 | ((_uCodePoint >> 6) & 0x3F));
                _Out += static_cast<char>(0x80 | (_uCodePoint & 0x3F));
            }
        }

        int HexDigit(char _C)
        {
            if (_C >= '0' && _C <= '9')
            {
                return _C - '0';
            }
            if (_C >= 'a' && _C <= 'f')
            {
                return _C - 'a' + 10;
            }
            if (_C >= 'A' && _C <= 'F')
            {
                return _C - 'A' + 10;
            }
            return -1;
        }

        bool IsDigit(char _C)
        {
            return _C >= '0' && _C <= '9';
        }

    } // namespace

    // Recursive descent over the text; one instance per Parse call.
    class JsonParser
    {
      public:
        explicit JsonParser(const std::string& _Text) : m_Text(_Text)
        {
        }

        std::optional<Json> Run(std::string* _pError)
        {
            Json value;
            SkipSpace();
            bool bok = ParseValue(value, 0);
            if (bok)
            {
                SkipSpace();
                if (m_nPos != m_Text.size())
                {
                    bok = Fail("unexpected text after the value");
                }
            }
            if (!bok)
            {
                if (_pError)
                {
                    *_pError = m_Error + " at offset " + std::to_string(m_nErrorPos);
                }
                return std::nullopt;
            }
            return value;
        }

      private:
        bool Fail(const char* _szMessage)
        {
            if (m_Error.empty())
            {
                m_Error = _szMessage;
                m_nErrorPos = m_nPos;
            }
            return false;
        }

        bool AtEnd() const
        {
            return m_nPos >= m_Text.size();
        }

        char Peek() const
        {
            return AtEnd() ? '\0' : m_Text[m_nPos];
        }

        void SkipSpace()
        {
            while (!AtEnd())
            {
                const char c = m_Text[m_nPos];
                if (c != ' ' && c != '\t' && c != '\n' && c != '\r')
                {
                    break;
                }
                ++m_nPos;
            }
        }

        bool ParseValue(Json& _Out, int _iDepth)
        {
            if (_iDepth > kMaxDepth)
            {
                return Fail("nested too deeply");
            }
            switch (Peek())
            {
            case '{':
                return ParseObject(_Out, _iDepth);
            case '[':
                return ParseArray(_Out, _iDepth);
            case '"':
                _Out = Json(std::string());
                return ParseString(_Out.m_String);
            case 't':
                return ParseLiteral("true", Json(true), _Out);
            case 'f':
                return ParseLiteral("false", Json(false), _Out);
            case 'n':
                return ParseLiteral("null", Json(), _Out);
            default:
                if (Peek() == '-' || IsDigit(Peek()))
                {
                    return ParseNumber(_Out);
                }
                return Fail(AtEnd() ? "unexpected end of text" : "expected a value");
            }
        }

        bool ParseLiteral(const char* _szWord, Json _Value, Json& _Out)
        {
            const std::string word(_szWord);
            if (m_Text.compare(m_nPos, word.size(), word) != 0)
            {
                return Fail("expected a value");
            }
            m_nPos += word.size();
            _Out = std::move(_Value);
            return true;
        }

        bool ParseNumber(Json& _Out)
        {
            const size_t nstart = m_nPos;
            bool bintegral = true;
            if (Peek() == '-')
            {
                ++m_nPos;
            }
            if (Peek() == '0')
            {
                ++m_nPos;
            }
            else if (IsDigit(Peek()))
            {
                while (IsDigit(Peek()))
                {
                    ++m_nPos;
                }
            }
            else
            {
                return Fail("expected a digit");
            }
            if (Peek() == '.')
            {
                bintegral = false;
                ++m_nPos;
                if (!IsDigit(Peek()))
                {
                    return Fail("expected a digit after the decimal point");
                }
                while (IsDigit(Peek()))
                {
                    ++m_nPos;
                }
            }
            if (Peek() == 'e' || Peek() == 'E')
            {
                bintegral = false;
                ++m_nPos;
                if (Peek() == '+' || Peek() == '-')
                {
                    ++m_nPos;
                }
                if (!IsDigit(Peek()))
                {
                    return Fail("expected a digit in the exponent");
                }
                while (IsDigit(Peek()))
                {
                    ++m_nPos;
                }
            }

            const char* pbegin = m_Text.data() + nstart;
            const char* pend = m_Text.data() + m_nPos;
            double fvalue = 0.0;
            const auto [pdone, ec] = std::from_chars(pbegin, pend, fvalue);
            if (ec == std::errc::result_out_of_range)
            {
                // Too large for a double: keep the sign, as most parsers do.
                fvalue = *pbegin == '-' ? -std::numeric_limits<double>::infinity()
                                        : std::numeric_limits<double>::infinity();
            }
            else if (ec != std::errc() || pdone != pend)
            {
                return Fail("bad number");
            }
            _Out = Json(fvalue);

            if (bintegral)
            {
                int64_t ivalue = 0;
                const auto [pidone, iec] = std::from_chars(pbegin, pend, ivalue);
                if (iec == std::errc() && pidone == pend)
                {
                    _Out.m_iInteger = ivalue;
                    _Out.m_bIsInteger = true;
                }
            }
            return true;
        }

        bool ParseHex4(uint32_t& _uOut)
        {
            if (m_nPos + 4 > m_Text.size())
            {
                return Fail("unfinished \\u escape");
            }
            _uOut = 0;
            for (int i = 0; i < 4; ++i)
            {
                const int idigit = HexDigit(m_Text[m_nPos + i]);
                if (idigit < 0)
                {
                    return Fail("bad \\u escape");
                }
                _uOut = (_uOut << 4) | static_cast<uint32_t>(idigit);
            }
            m_nPos += 4;
            return true;
        }

        // At the opening quote; leaves the position after the closing one.
        bool ParseString(std::string& _Out)
        {
            ++m_nPos;
            while (true)
            {
                if (AtEnd())
                {
                    return Fail("unterminated string");
                }
                const char c = m_Text[m_nPos];
                if (c == '"')
                {
                    ++m_nPos;
                    return true;
                }
                if (static_cast<unsigned char>(c) < 0x20)
                {
                    return Fail("control character in a string");
                }
                if (c != '\\')
                {
                    _Out += c;
                    ++m_nPos;
                    continue;
                }

                ++m_nPos;
                if (AtEnd())
                {
                    return Fail("unterminated string");
                }
                const char escape = m_Text[m_nPos++];
                switch (escape)
                {
                case '"':
                    _Out += '"';
                    break;
                case '\\':
                    _Out += '\\';
                    break;
                case '/':
                    _Out += '/';
                    break;
                case 'b':
                    _Out += '\b';
                    break;
                case 'f':
                    _Out += '\f';
                    break;
                case 'n':
                    _Out += '\n';
                    break;
                case 'r':
                    _Out += '\r';
                    break;
                case 't':
                    _Out += '\t';
                    break;
                case 'u':
                {
                    uint32_t ucode = 0;
                    if (!ParseHex4(ucode))
                    {
                        return false;
                    }
                    if (ucode >= 0xD800 && ucode <= 0xDBFF)
                    {
                        // A high surrogate pairs with the low one that must
                        // follow; alone it becomes U+FFFD.
                        uint32_t ulow = 0;
                        if (m_Text.compare(m_nPos, 2, "\\u") == 0)
                        {
                            const size_t nsave = m_nPos;
                            m_nPos += 2;
                            if (!ParseHex4(ulow))
                            {
                                return false;
                            }
                            if (ulow >= 0xDC00 && ulow <= 0xDFFF)
                            {
                                ucode = 0x10000 + ((ucode - 0xD800) << 10) + (ulow - 0xDC00);
                            }
                            else
                            {
                                m_nPos = nsave;
                                ucode = 0xFFFD;
                            }
                        }
                        else
                        {
                            ucode = 0xFFFD;
                        }
                    }
                    else if (ucode >= 0xDC00 && ucode <= 0xDFFF)
                    {
                        ucode = 0xFFFD;
                    }
                    AppendUtf8(_Out, ucode);
                    break;
                }
                default:
                    --m_nPos;
                    return Fail("bad escape");
                }
            }
        }

        bool ParseArray(Json& _Out, int _iDepth)
        {
            _Out = Json::Array();
            ++m_nPos;
            SkipSpace();
            if (Peek() == ']')
            {
                ++m_nPos;
                return true;
            }
            while (true)
            {
                SkipSpace();
                Json item;
                if (!ParseValue(item, _iDepth + 1))
                {
                    return false;
                }
                _Out.m_Items.push_back(std::move(item));
                SkipSpace();
                if (Peek() == ',')
                {
                    ++m_nPos;
                    continue;
                }
                if (Peek() == ']')
                {
                    ++m_nPos;
                    return true;
                }
                return Fail("expected ',' or ']'");
            }
        }

        bool ParseObject(Json& _Out, int _iDepth)
        {
            _Out = Json::Object();
            ++m_nPos;
            SkipSpace();
            if (Peek() == '}')
            {
                ++m_nPos;
                return true;
            }
            while (true)
            {
                SkipSpace();
                if (Peek() != '"')
                {
                    return Fail("expected a key");
                }
                std::string key;
                if (!ParseString(key))
                {
                    return false;
                }
                SkipSpace();
                if (Peek() != ':')
                {
                    return Fail("expected ':'");
                }
                ++m_nPos;
                SkipSpace();
                Json value;
                if (!ParseValue(value, _iDepth + 1))
                {
                    return false;
                }
                _Out.Set(key, std::move(value)); // a repeated key: the last wins
                SkipSpace();
                if (Peek() == ',')
                {
                    ++m_nPos;
                    continue;
                }
                if (Peek() == '}')
                {
                    ++m_nPos;
                    return true;
                }
                return Fail("expected ',' or '}'");
            }
        }

        const std::string& m_Text;
        size_t m_nPos = 0;
        std::string m_Error;
        size_t m_nErrorPos = 0;
    };

    Json::Json(std::nullptr_t)
    {
    }

    Json::Json(bool _bValue) : m_Type(Type::Bool), m_bValue(_bValue)
    {
    }

    Json::Json(double _fValue) : m_Type(Type::Number), m_fNumber(_fValue)
    {
    }

    Json::Json(const char* _szValue) : m_Type(Type::String), m_String(_szValue ? _szValue : "")
    {
    }

    Json::Json(std::string _Value) : m_Type(Type::String), m_String(std::move(_Value))
    {
    }

    Json Json::Array()
    {
        Json value;
        value.m_Type = Type::Array;
        return value;
    }

    Json Json::Object()
    {
        Json value;
        value.m_Type = Type::Object;
        return value;
    }

    std::optional<Json> Json::Parse(const std::string& _Text, std::string* _pError)
    {
        GITGUD_PROFILE_FUNCTION();
        return JsonParser(_Text).Run(_pError);
    }

    bool Json::AsBool(bool _bFallback) const
    {
        return m_Type == Type::Bool ? m_bValue : _bFallback;
    }

    double Json::AsNumber(double _fFallback) const
    {
        return m_Type == Type::Number ? m_fNumber : _fFallback;
    }

    int64_t Json::AsInt(int64_t _iFallback) const
    {
        if (m_Type != Type::Number)
        {
            return _iFallback;
        }
        if (m_bIsInteger)
        {
            return m_iInteger;
        }
        // 2^63 as a double: anything at or beyond doesn't fit.
        constexpr double klimit = 9223372036854775808.0;
        if (!std::isfinite(m_fNumber) || m_fNumber >= klimit || m_fNumber < -klimit)
        {
            return _iFallback;
        }
        return static_cast<int64_t>(m_fNumber);
    }

    const std::string& Json::AsString() const
    {
        static const std::string kempty;
        return m_Type == Type::String ? m_String : kempty;
    }

    std::string Json::AsString(const std::string& _Fallback) const
    {
        return m_Type == Type::String ? m_String : _Fallback;
    }

    size_t Json::Size() const
    {
        return (m_Type == Type::Array || m_Type == Type::Object) ? m_Items.size() : 0;
    }

    const Json& Json::operator[](size_t _nIndex) const
    {
        if (m_Type != Type::Array || _nIndex >= m_Items.size())
        {
            return NullValue();
        }
        return m_Items[_nIndex];
    }

    Json& Json::Push(Json _Value)
    {
        if (m_Type == Type::Null)
        {
            m_Type = Type::Array;
        }
        if (m_Type == Type::Array)
        {
            m_Items.push_back(std::move(_Value));
        }
        return *this;
    }

    const std::vector<Json>& Json::Items() const
    {
        static const std::vector<Json> knone;
        return m_Type == Type::Array ? m_Items : knone;
    }

    const Json& Json::operator[](const std::string& _Key) const
    {
        if (m_Type == Type::Object)
        {
            for (size_t i = 0; i < m_Keys.size(); ++i)
            {
                if (m_Keys[i] == _Key)
                {
                    return m_Items[i];
                }
            }
        }
        return NullValue();
    }

    bool Json::Has(const std::string& _Key) const
    {
        if (m_Type != Type::Object)
        {
            return false;
        }
        for (const std::string& key : m_Keys)
        {
            if (key == _Key)
            {
                return true;
            }
        }
        return false;
    }

    Json& Json::Set(const std::string& _Key, Json _Value)
    {
        At(_Key) = std::move(_Value);
        return *this;
    }

    Json& Json::At(const std::string& _Key)
    {
        if (m_Type == Type::Null)
        {
            m_Type = Type::Object;
        }
        if (m_Type != Type::Object)
        {
            // Not an object: hand back a scratch value so writes go nowhere.
            static thread_local Json tscratch;
            tscratch = Json();
            return tscratch;
        }
        for (size_t i = 0; i < m_Keys.size(); ++i)
        {
            if (m_Keys[i] == _Key)
            {
                return m_Items[i];
            }
        }
        m_Keys.push_back(_Key);
        m_Items.emplace_back();
        return m_Items.back();
    }

    const std::vector<std::string>& Json::Keys() const
    {
        static const std::vector<std::string> knone;
        return m_Type == Type::Object ? m_Keys : knone;
    }

    bool Json::operator==(const Json& _Other) const
    {
        if (m_Type != _Other.m_Type)
        {
            return false;
        }
        switch (m_Type)
        {
        case Type::Null:
            return true;
        case Type::Bool:
            return m_bValue == _Other.m_bValue;
        case Type::Number:
            if (m_bIsInteger && _Other.m_bIsInteger)
            {
                return m_iInteger == _Other.m_iInteger;
            }
            return m_fNumber == _Other.m_fNumber;
        case Type::String:
            return m_String == _Other.m_String;
        case Type::Array:
            return m_Items == _Other.m_Items;
        case Type::Object:
            // Key order doesn't matter for equality.
            if (m_Keys.size() != _Other.m_Keys.size())
            {
                return false;
            }
            for (size_t i = 0; i < m_Keys.size(); ++i)
            {
                if (!_Other.Has(m_Keys[i]) || _Other[m_Keys[i]] != m_Items[i])
                {
                    return false;
                }
            }
            return true;
        }
        return false;
    }

    std::string Json::Dump() const
    {
        GITGUD_PROFILE_FUNCTION();
        std::string out;
        DumpTo(out);
        return out;
    }

    void Json::DumpTo(std::string& _Out) const
    {
        switch (m_Type)
        {
        case Type::Null:
            _Out += "null";
            return;
        case Type::Bool:
            _Out += m_bValue ? "true" : "false";
            return;
        case Type::Number:
        {
            if (m_bIsInteger)
            {
                _Out += std::to_string(m_iInteger);
                return;
            }
            if (!std::isfinite(m_fNumber))
            {
                _Out += "null";
                return;
            }
            // Shortest text that reads back as the same double.
            char buffer[32];
            const auto [pend, ec] = std::to_chars(buffer, buffer + sizeof(buffer), m_fNumber);
            _Out.append(buffer, ec == std::errc() ? pend : buffer);
            return;
        }
        case Type::String:
            _Out += JsonQuote(m_String);
            return;
        case Type::Array:
            _Out += '[';
            for (size_t i = 0; i < m_Items.size(); ++i)
            {
                if (i > 0)
                {
                    _Out += ',';
                }
                m_Items[i].DumpTo(_Out);
            }
            _Out += ']';
            return;
        case Type::Object:
            _Out += '{';
            for (size_t i = 0; i < m_Keys.size(); ++i)
            {
                if (i > 0)
                {
                    _Out += ',';
                }
                _Out += JsonQuote(m_Keys[i]);
                _Out += ':';
                m_Items[i].DumpTo(_Out);
            }
            _Out += '}';
            return;
        }
    }

    std::string JsonQuote(const std::string& _Text)
    {
        static const char* kszhex = "0123456789abcdef";
        std::string out;
        out.reserve(_Text.size() + 2);
        out += '"';
        for (const char c : _Text)
        {
            switch (c)
            {
            case '"':
                out += "\\\"";
                break;
            case '\\':
                out += "\\\\";
                break;
            case '\b':
                out += "\\b";
                break;
            case '\f':
                out += "\\f";
                break;
            case '\n':
                out += "\\n";
                break;
            case '\r':
                out += "\\r";
                break;
            case '\t':
                out += "\\t";
                break;
            default:
                if (static_cast<unsigned char>(c) < 0x20)
                {
                    out += "\\u00";
                    out += kszhex[(c >> 4) & 0xF];
                    out += kszhex[c & 0xF];
                }
                else
                {
                    out += c;
                }
            }
        }
        out += '"';
        return out;
    }

} // namespace gitgud::app
