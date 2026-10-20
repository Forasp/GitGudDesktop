#include "speech/OnnxPatch.h"

#include "platform/Shell.h"

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <vector>

namespace gitgud::speech
{

    namespace
    {

        struct Field
        {
            uint64_t m_uNumber = 0;
            int m_iWire = 0;
            std::size_t m_nBegin = 0; // the whole field, key included
            std::size_t m_nEnd = 0;
            std::size_t m_nPayload = 0; // length-delimited: its bytes
            std::size_t m_nPayloadLength = 0;
        };

        bool Varint(const std::string& _Bytes, std::size_t& _nAt, uint64_t& _uOut)
        {
            _uOut = 0;
            for (int ishift = 0; ishift < 64; ishift += 7)
            {
                if (_nAt >= _Bytes.size())
                {
                    return false;
                }
                const unsigned char c = static_cast<unsigned char>(_Bytes[_nAt++]);
                _uOut |= static_cast<uint64_t>(c & 0x7F) << ishift;
                if (!(c & 0x80))
                {
                    return true;
                }
            }
            return false;
        }

        std::string EncodeVarint(uint64_t _uValue)
        {
            std::string out;
            do
            {
                unsigned char c = _uValue & 0x7F;
                _uValue >>= 7;
                if (_uValue)
                {
                    c |= 0x80;
                }
                out += static_cast<char>(c);
            } while (_uValue);
            return out;
        }

        std::string LengthDelimited(uint64_t _uField, const std::string& _Payload)
        {
            return EncodeVarint(_uField << 3 | 2) + EncodeVarint(_Payload.size()) + _Payload;
        }

        bool Fields(const std::string& _Bytes, std::vector<Field>& _Out)
        {
            std::size_t nat = 0;
            while (nat < _Bytes.size())
            {
                Field f;
                f.m_nBegin = nat;
                uint64_t ukey = 0;
                if (!Varint(_Bytes, nat, ukey))
                {
                    return false;
                }
                f.m_uNumber = ukey >> 3;
                f.m_iWire = static_cast<int>(ukey & 7);
                uint64_t uvalue = 0;
                switch (f.m_iWire)
                {
                case 0:
                    if (!Varint(_Bytes, nat, uvalue))
                    {
                        return false;
                    }
                    break;
                case 1:
                    nat += 8;
                    break;
                case 2:
                    if (!Varint(_Bytes, nat, uvalue) || nat + uvalue > _Bytes.size())
                    {
                        return false;
                    }
                    f.m_nPayload = nat;
                    f.m_nPayloadLength = static_cast<std::size_t>(uvalue);
                    nat += static_cast<std::size_t>(uvalue);
                    break;
                case 5:
                    nat += 4;
                    break;
                default:
                    return false;
                }
                if (nat > _Bytes.size())
                {
                    return false;
                }
                f.m_nEnd = nat;
                _Out.push_back(f);
            }
            return true;
        }

        std::string Payload(const std::string& _Bytes, const Field& _Field)
        {
            return _Bytes.substr(_Field.m_nPayload, _Field.m_nPayloadLength);
        }

    } // namespace

    bool SetMatMulNBitsAccuracyBytes(
        const std::string& _Model, int _iLevel, std::string& _Out, int& _iChanged)
    {
        _iChanged = 0;
        std::vector<Field> model;
        if (!Fields(_Model, model))
        {
            return false;
        }
        // AttributeProto: name (1), i (3), type (20) = INT (2).
        const std::string attribute = LengthDelimited(1, "accuracy_level") +
                                      EncodeVarint(3 << 3 | 0) +
                                      EncodeVarint(static_cast<uint64_t>(_iLevel)) +
                                      EncodeVarint(20 << 3 | 0) + EncodeVarint(2);
        bool bgraph = false;
        std::string out;
        for (const Field& f : model)
        {
            if (f.m_uNumber != 7 || f.m_iWire != 2) // ModelProto.graph
            {
                out.append(_Model, f.m_nBegin, f.m_nEnd - f.m_nBegin);
                continue;
            }
            bgraph = true;
            const std::string graph = Payload(_Model, f);
            std::vector<Field> graphFields;
            if (!Fields(graph, graphFields))
            {
                return false;
            }
            std::string newGraph;
            for (const Field& g : graphFields)
            {
                if (g.m_uNumber == 1 && g.m_iWire == 2) // GraphProto.node
                {
                    const std::string node = Payload(graph, g);
                    std::vector<Field> nodeFields;
                    if (Fields(node, nodeFields))
                    {
                        std::string op;
                        bool bhas = false;
                        for (const Field& n : nodeFields)
                        {
                            if (n.m_uNumber == 4 && n.m_iWire == 2) // op_type
                            {
                                op = Payload(node, n);
                            }
                            else if (n.m_uNumber == 5 && n.m_iWire == 2) // attribute
                            {
                                const std::string attr = Payload(node, n);
                                std::vector<Field> attrFields;
                                if (Fields(attr, attrFields))
                                {
                                    for (const Field& a : attrFields)
                                    {
                                        if (a.m_uNumber == 1 && a.m_iWire == 2 &&
                                            Payload(attr, a) == "accuracy_level")
                                        {
                                            bhas = true;
                                        }
                                    }
                                }
                            }
                        }
                        if (op == "MatMulNBits" && !bhas)
                        {
                            newGraph += LengthDelimited(1, node + LengthDelimited(5, attribute));
                            ++_iChanged;
                            continue;
                        }
                    }
                }
                newGraph.append(graph, g.m_nBegin, g.m_nEnd - g.m_nBegin);
            }
            out += LengthDelimited(7, newGraph);
        }
        if (!bgraph)
        {
            return false;
        }
        _Out = std::move(out);
        return true;
    }

    bool SetMatMulNBitsAccuracy(const std::string& _In, const std::string& _Out, int _iLevel,
        int& _iChanged, std::string& _Error)
    {
        std::ifstream file(std::filesystem::u8path(_In), std::ios::binary);
        if (!file)
        {
            _Error = "cannot read " + _In;
            return false;
        }
        std::stringstream ss;
        ss << file.rdbuf();
        std::string patched;
        if (!SetMatMulNBitsAccuracyBytes(ss.str(), _iLevel, patched, _iChanged))
        {
            _Error = _In + " isn't an ONNX model";
            return false;
        }
        return platform::WriteFileAtomically(_Out, patched, _Error);
    }

} // namespace gitgud::speech
