#pragma once

// -----------------------------------------------------------------------------
// Raster — small anti-aliased drawing primitives over imaging::Image, shared
// by the graph renderers. Shapes are rasterised with a signed distance per
// pixel inside each shape's bounding box, which gives smooth edges without a
// graphics library and stays cheap for the few-thousand-pixel shapes we draw.
// Colours are straight RGB; alpha goes through the per-call opacity.
// -----------------------------------------------------------------------------

#include <cstdint>
#include <vector>

#include "imaging/ImageDiff.h"

namespace gitgud::imaging::raster
{

    struct Point
    {
        float m_fX = 0.0f;
        float m_fY = 0.0f;
    };

    struct Colour
    {
        float m_fR = 0.0f;
        float m_fG = 0.0f;
        float m_fB = 0.0f;
    };

    // 0xRRGGBB -> Colour.
    Colour FromHex(std::uint32_t _uiRgb);

    // An image of the given size, every pixel set to `_Fill` at `_fAlpha`.
    Image MakeImage(int _iWidth, int _iHeight, const Colour& _Fill, float _fAlpha);

    // Straight-alpha "over" of one pixel.
    void Blend(Image& _Img, int _iX, int _iY, const Colour& _C, float _fAlpha);

    // A thick polyline drawn as one shape (no darker joints).
    void DrawPolyline(Image& _Img, const std::vector<Point>& _Points, float _fWidth,
        const Colour& _C, float _fOpacity);

    void DrawDisc(Image& _Img, const Point& _Centre, float _fRadius, const Colour& _C);
    void DrawRing(
        Image& _Img, const Point& _Centre, float _fRadius, float _fWidth, const Colour& _C);

    // Axis-aligned rectangle with rounded corners (radius 0 = square), filled.
    void FillRoundedRect(Image& _Img, float _fX, float _fY, float _fWidth, float _fHeight,
        float _fRadius, const Colour& _C, float _fOpacity);
    // Its outline, `_fLine` pixels thick, inside the rectangle.
    void StrokeRoundedRect(Image& _Img, float _fX, float _fY, float _fWidth, float _fHeight,
        float _fRadius, float _fLine, const Colour& _C, float _fOpacity);

    // A convex polygon (points in either winding order), filled.
    void FillConvex(
        Image& _Img, const std::vector<Point>& _Points, const Colour& _C, float _fOpacity);

    // A horizontal colour ramp from `_From` (left) to `_To` (right).
    void FillGradientRect(Image& _Img, float _fX, float _fY, float _fWidth, float _fHeight,
        const Colour& _From, float _fFromAlpha, const Colour& _To, float _fToAlpha);

} // namespace gitgud::imaging::raster
