#pragma once

// -----------------------------------------------------------------------------
// The public half of the key that signs each release's update manifest, as
// base64 of the P-256 point X||Y (64 bytes). tools/new-update-key.ps1 makes a
// key pair and writes this line; the private half is the
// GITGUD_UPDATE_SIGNING_KEY secret in GitHub Actions.
//
// Empty: this build can't verify updates, so it never installs one.
// -----------------------------------------------------------------------------

namespace gitgud::update
{

    constexpr const char* kUpdatePublicKey = "+qRnHtwt16ucQCVUsXxTT6qJA3xrzdhm8+FdHG4D/hs8vfUKGJDapUgbEva565+CP73TmNvsxKAQAFuGs3vzRg==";

} // namespace gitgud::update
