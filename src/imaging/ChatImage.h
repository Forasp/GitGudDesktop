#pragma once

// -----------------------------------------------------------------------------
// ChatImage: pictures in a conversation with Claude Code. Pasted or dropped
// images go to the model as base64 image blocks, within its limits; images
// in its replies and tool results are shown as thumbnails.
//
// UI-agnostic, like ImageDiff: encoded bytes in, RGBA8 (Image) or encoded
// bytes out.
// -----------------------------------------------------------------------------

#include <string>

#include "imaging/ImageDiff.h"

namespace gitgud::imaging
{

    // "image/png", "image/jpeg", "image/gif" or "image/webp" from the bytes'
    // signature; "" for anything else.
    std::string SniffMediaType(const std::string& _Bytes);

    // The file extension for a media type SniffMediaType returns ("png", ...).
    std::string ExtensionOf(const std::string& _MediaType);

    // Scale `_In` down to fit within _iMaxWidth x _iMaxHeight, keeping its
    // aspect ratio (never up). A copy when it fits already.
    Image Fit(const Image& _In, int _iMaxWidth, int _iMaxHeight);

    bool EncodePng(const Image& _Img, std::string& _Out);
    bool EncodeJpeg(const Image& _Img, int _iQuality, std::string& _Out);

    // The width and height in an encoded image's header, without decoding it.
    bool ReadSize(const std::string& _Bytes, int& _iWidth, int& _iHeight);

    std::string Base64Encode(const std::string& _Bytes);
    bool Base64Decode(const std::string& _Text, std::string& _Out);

    // An image as the model takes it: a type it reads, at most kMaxModelEdge
    // on its long edge and kMaxModelBytes encoded. One that is already within
    // them goes as is; a larger one is scaled down and re-encoded (PNG, or
    // JPEG when the PNG is still too big).
    constexpr int kMaxModelEdge = 1568;
    constexpr std::size_t kMaxModelBytes = 3750 * 1024; // 5 MB once base64
    bool PrepareForModel(const std::string& _Bytes, std::string& _MediaType, std::string& _Out,
        std::string& _Error);

} // namespace gitgud::imaging
