#pragma once

// -----------------------------------------------------------------------------
// ChatImages: the pictures in Claude Code conversations, as files.
//
// Claude Code's stream and transcripts carry images as base64 blocks (a
// pasted screenshot, the Read tool on an image, a computer-use screenshot).
// They are written once to the local data folder's chat-images/, named by
// their content, so the UI shows them from a path: live and when a
// transcript is read again. The blocks handed on carry the path instead of
// the data.
// -----------------------------------------------------------------------------

#include <string>
#include <vector>

#include "app/Json.h"

namespace gitgud::agent
{

    // The folder images are kept in (LocalDataDirectory()/chat-images).
    std::string ChatImageDirectory();

    // Write an image's bytes there (once: the name is a hash of them).
    // Returns its path, or "" when it couldn't be written.
    std::string StoreChatImage(const std::string& _Bytes, const std::string& _MediaType);

    // Each base64 image block in `_Content` (an array of content blocks, as
    // in a message or a tool result) stored, and replaced with
    // { "type": "image", "path": ... }. Returns the paths, in order.
    // Anything else (a string, other blocks) is left as it is.
    std::vector<std::string> TakeChatImages(app::Json& _Content);

    // The paths of the base64 image blocks in `_Content` (stored as above),
    // without changing it.
    std::vector<std::string> ChatImagesIn(const app::Json& _Content);

    // An image file as a base64 image block for a user message, prepared for
    // the model (imaging/ChatImage.h, PrepareForModel). Null on failure.
    app::Json ImageBlockFromFile(const std::string& _Path, std::string& _Error);

} // namespace gitgud::agent
