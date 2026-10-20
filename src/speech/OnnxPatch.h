#pragma once

// -----------------------------------------------------------------------------
// OnnxPatch: small edits to ONNX graph files without an ONNX library (a raw
// protobuf walk). Chatterbox Turbo's quantized graphs leave accuracy_level
// unset on their MatMulNBits nodes, so ONNX Runtime takes a slow path;
// setting it to 4 (int8 compute) makes a language-model step two to thirty
// times faster. The weights (external .onnx_data files) aren't touched.
// -----------------------------------------------------------------------------

#include <string>

namespace gitgud::speech
{

    // Copy the graph at `_In` to `_Out` with accuracy_level=`_iLevel` on every
    // MatMulNBits node that has none. `_iChanged` gets how many changed.
    // False with `_Error` when `_In` isn't an ONNX model.
    bool SetMatMulNBitsAccuracy(const std::string& _In, const std::string& _Out, int _iLevel,
        int& _iChanged, std::string& _Error);

    // The same on bytes (for tests).
    bool SetMatMulNBitsAccuracyBytes(
        const std::string& _Model, int _iLevel, std::string& _Out, int& _iChanged);

} // namespace gitgud::speech
