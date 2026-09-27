#pragma once

// -----------------------------------------------------------------------------
// ImageDiff — decode two versions of an image and compute what changed.
//
// UI-agnostic: everything here is plain RGBA8 buffers. The Lua binding reads
// the file versions from the repository, runs Compare(), and hands the
// resulting buffers to the UI backend as textures.
//
// Outputs of Compare() share one canvas (the union of both sizes, anchored
// top-left) so they line up pixel-for-pixel when shown side by side:
//   * m_Before / m_After — the inputs flattened onto a checkerboard
//   * m_Difference       — the after image dimmed to grey, with every changed
//                          pixel painted in the highlight colour (brighter =
//                          bigger change); pixels outside one image count as
//                          changed
//   * m_Onion            — before and after blended 50/50
// -----------------------------------------------------------------------------

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace gitgud::imaging
{

    struct Image
    {
        int m_iWidth = 0;
        int m_iHeight = 0;
        std::vector<std::uint8_t> m_Rgba; // row-major, 4 bytes per pixel

        bool Empty() const
        {
            return m_iWidth <= 0 || m_iHeight <= 0;
        }
    };

    // True for extensions stb can decode (png, jpg/jpeg, gif, bmp, tga, psd,
    // pnm/ppm/pgm, hdr, pic). Case-insensitive.
    bool IsImagePath(const std::string& _Path);

    // Decode an encoded image. Returns false (and a reason) on failure.
    bool Decode(const std::string& _Bytes, Image& _Out, std::string& _Error);

    struct Comparison
    {
        Image m_Before;
        Image m_After;
        Image m_Difference;
        Image m_Onion;
        std::size_t m_ChangedPixels = 0;
        std::size_t m_TotalPixels = 0;
    };

    // Either input may be Empty() (file added or deleted). `_uiHighlight` is
    // 0xRRGGBB.
    Comparison Compare(const Image& _Before, const Image& _After, std::uint32_t _uiHighlight);

    // Encode RGBA8 pixels as a PNG file (used by the test harness's
    // screenshots). Returns false on failure.
    bool WritePng(const std::string& _Path, const Image& _Image);

} // namespace gitgud::imaging
