import Foundation

/// Sole-renderer entry point. Preview, still, and export MUST share settings and behavior
/// through this actor; only resolution may adapt for preview. Algorithms, glyphs, palettes,
/// and anchoring are intent-invariant. `atkinson` and `floydSteinberg` reuse the Unit 2 exact
/// fixed-point Metal scanline diffusion (`MetalErrorDiffusionSpike`); `threshold` and `bayer`
/// use CPU references. ASCII uses bundled glyph sets only; custom glyphs are not offered.
actor MetalFrameRenderer {
    private let diffusion: MetalErrorDiffusionSpike?

    init() { self.diffusion = try? MetalErrorDiffusionSpike() }

    /// Render one frame at the request dimensions, one byte per oriented pixel
    /// (`width × height`). For `postToneMapSDR` the byte is stylized brightness;
    /// otherwise it is a palette index (0…N-1, N ≤ 16).
    func render(request: RenderRequest, settings: RenderSettings,
                pixels: [UInt8], sourceWidth: Int, sourceHeight: Int) throws -> [UInt8] {
        guard request.width > 0, request.height > 0,
              sourceWidth > 0, sourceHeight > 0,
              pixels.count == sourceWidth * sourceHeight else {
            throw RenderSettingsError.invalidDimensions
        }
        let adapted = adapt(pixels, sw: sourceWidth, sh: sourceHeight,
                            w: request.width, h: request.height)
        let toned = settings.toneMap ? adapted.map(Self.toneMap) : adapted
        switch settings.style {
        case .dither(let mode):
            return try ditherStylize(toned, width: request.width, height: request.height,
                                     mode: mode, settings: settings)
        case .ascii(let set):
            return asciiStylize(toned, width: request.width, height: request.height,
                                cellSize: settings.cellSize, set: set, settings: settings)
        }
    }

    private func adapt(_ pixels: [UInt8], sw: Int, sh: Int, w: Int, h: Int) -> [UInt8] {
        (0..<h).flatMap { y in (0..<w).map { x in pixels[(y * sh / h) * sw + x * sw / w] } }
    }

    private func ditherStylize(_ pixels: [UInt8], width: Int, height: Int,
                               mode: DitherMode, settings: RenderSettings) throws -> [UInt8] {
        let stylized: [UInt8]
        switch mode {
        case .threshold: stylized = pixels.map { $0 >= 128 ? 255 : 0 }
        case .bayer: stylized = bayerDither(pixels, width: width, height: height)
        case .atkinson, .floydSteinberg:
            guard let diffusion else { throw ErrorDiffusionSpikeError.metalUnavailable }
            let algorithm: ErrorDiffusionAlgorithm = mode == .atkinson ? .atkinson : .floydSteinberg
            stylized = try diffusion.render(pixels, width: width, height: height, algorithm: algorithm)
        }
        return applyPaletteAndBackground(stylized, settings: settings)
    }

    /// 4×4 Bayer ordered dither, exact threshold per pixel against the standard matrix.
    private func bayerDither(_ pixels: [UInt8], width: Int, height: Int) -> [UInt8] {
        let matrix = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
        return (0..<height).flatMap { y in
            (0..<width).map { x -> UInt8 in
                let threshold = matrix[(y % 4) * 4 + (x % 4)] * 16 + 8
                return pixels[y * width + x] >= UInt8(truncatingIfNeeded: threshold) ? 255 : 0
            }
        }
    }

    /// Per `cellSize×cellSize` block: average source brightness, map to a bundled glyph via
    /// inverse density (dark input → densest glyph), then emit one stylized brightness per
    /// pixel — constant within a cell so palette matching is uniform.
    private func asciiStylize(_ pixels: [UInt8], width: Int, height: Int, cellSize: Int,
                              set: ASCIIGlyphSet, settings: RenderSettings) -> [UInt8] {
        let c = max(1, cellSize), span = set.glyphs.count - 1
        var output = [UInt8](repeating: 0, count: width * height)
        for cellY in stride(from: 0, to: height, by: c) {
            for cellX in stride(from: 0, to: width, by: c) {
                let endY = min(cellY + c, height), endX = min(cellX + c, width)
                var sum = 0, count = 0
                for y in cellY..<endY { for x in cellX..<endX {
                    sum += Int(pixels[y * width + x]); count += 1
                } }
                let avg = count > 0 ? sum / count : 0
                let glyphIndex = (255 - avg) * span / 255
                let ink = UInt8(truncatingIfNeeded: 255 - glyphIndex * 255 / max(1, span))
                for y in cellY..<endY { for x in cellX..<endX { output[y * width + x] = ink } }
            }
        }
        return applyPaletteAndBackground(output, settings: settings)
    }

    /// Deterministic BT.2390-to-100-nit linear Rec.709 EETF (R3-001 carry-forward).
    /// PQ code -> PQ inverse EOTF -> linear scene luminance (0..1 = 0..10000 nits) ->
    /// compressive roll-off strictly below display clip (so Bayer/ASCII keep highlight detail) ->
    /// sRGB OETF -> 8-bit Rec.709 brightness.
    static func toneMap(_ value: UInt8) -> UInt8 {
        let p = Double(value) / 255.0
        let m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
        let t = pow(p, 1.0 / m2)
        let L = pow(max(t - c1, 0.0) / max(c2 - c3 * t, 1e-12), 1.0 / m1)
        let sdr = 1.0 - exp(-1.78 * L)
        let srgb = sdr <= 0.0031308 ? 12.92 * sdr : 1.055 * pow(sdr, 1.0 / 2.4) - 0.055
        return UInt8(max(0, min(255, srgb * 255)))
    }

    private func applyPaletteAndBackground(_ stylized: [UInt8], settings: RenderSettings) -> [UInt8] {
        switch settings.background {
        case .postToneMapSDR: return stylized
        case .blackOnWhite: return stylized.map { settings.palette.nearest(toBrightness: $0) }
        case .whiteOnBlack: return stylized.map { settings.palette.nearest(toBrightness: 255 &- $0) }
        }
    }
}