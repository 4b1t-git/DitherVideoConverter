import Foundation

/// Sole-renderer entry point. Preview, still, and export MUST share settings and behavior
/// through this actor; only resolution may adapt for preview. Algorithms, glyphs, palettes,
/// and anchoring are intent-invariant. `atkinson` and `floydSteinberg` reuse the Unit 2 exact
/// fixed-point Metal scanline diffusion (`MetalErrorDiffusionSpike`); `threshold` and `bayer`
/// use CPU references. ASCII uses bundled glyph sets only; custom glyphs are not offered.
actor MetalFrameRenderer {
    private let diffusion: MetalErrorDiffusionSpike?

    /// Rasterized glyph sets, keyed by the two things that decide their pixels.
    ///
    /// A 1080p frame at cell size 4 is over 129,000 cells; rasterizing through Core Text once per
    /// cell would run the type engine that many times per frame to produce ten distinct bitmaps.
    /// The atlas is a pure function of `(set, cellSize)`, so it is built once and read by every
    /// cell of every later frame. Actor isolation is what makes a plain mutable dictionary safe:
    /// `asciiStylize` only ever runs on this actor's executor.
    private var atlases: [AtlasKey: GlyphAtlas] = [:]

    private struct AtlasKey: Hashable {
        let set: ASCIIGlyphSet
        let cellSize: Int
    }

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
        // ONE place, ahead of everything: the inversion is applied to the adapted source before
        // tone mapping and before the style switch, so every style inherits the same complemented
        // frame and no style can hold a different opinion about what "inverted" means. Putting it
        // inside `asciiStylize` would fix ASCII and leave dither with a flag that does nothing.
        //
        // BEFORE the tone map, not after, and the two are genuinely different pictures because the
        // PQ→SDR transfer is non-linear. `toneMap` is strongly convex — its pinned goldens put
        // everything up to 192 below 112 — so complementing its OUTPUT lands most of the frame in
        // 255…143, i.e. back at the sparse end of the glyph ramp: over the whole 0…255 input range
        // that order sends 121 values into the empty glyph slot and never reaches the densest one
        // at all, which is the blank-subject defect this flag exists to remove. Inverting the raw
        // source instead leaves the tone map doing its normal job on a complemented frame: the
        // output spreads over all ten slots and stays inside the calibrated 0…235 range the
        // roll-off deliberately keeps below display clip, rather than being pushed above it by a
        // later subtraction. It is also what the flag's name promises — the SOURCE is inverted, and
        // the pipeline that follows is unchanged.
        let inverted = settings.invertSource ? adapted.map { 255 &- $0 } : adapted
        let toned = settings.toneMap ? inverted.map(Self.toneMap) : inverted
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
    /// inverse density (dark input → densest glyph), then DRAW that glyph into the cell.
    ///
    /// The selection below is only correct while slot 0 is the LIGHTEST glyph and the last slot the
    /// densest, and it does not check: `GlyphAtlas` guarantees that by sorting its own entries on the
    /// ink it measured, so the property holds for whichever face resolves at runtime. Nothing here
    /// may reorder or reindex `atlas.bitmaps`.
    ///
    /// The glyph selection is unchanged, deliberately: it is the spec'd mapping, and
    /// `testASCIIDensityIncreasesWhenCellSizeDecreases` pins the property it exists for. What
    /// changed is everything after it — this used to convert the chosen glyph's INDEX back into one
    /// brightness (`255 - glyphIndex * 255 / span`) and fill the whole cell with it, throwing the
    /// character away and leaving a mosaic. `set.glyphs` was read for `.count` alone.
    ///
    /// Polarity is inherited, not invented: the byte emitted here is stylized BRIGHTNESS, so ink is
    /// DARK (0) and background LIGHT (255). The replaced line said the same — the densest glyph
    /// (`glyphIndex == span`) produced 0, the sparsest 255 — and `applyPaletteAndBackground`
    /// resolves that brightness exactly as it does for a dither mode. So coverage inverts: full ink
    /// (255 in the atlas) becomes brightness 0.
    private func asciiStylize(_ pixels: [UInt8], width: Int, height: Int, cellSize: Int,
                              set: ASCIIGlyphSet, settings: RenderSettings) -> [UInt8] {
        let c = max(1, cellSize), span = set.glyphs.count - 1
        let atlas = atlas(for: set, cellSize: c)
        var output = [UInt8](repeating: 0, count: width * height)
        for cellY in stride(from: 0, to: height, by: c) {
            for cellX in stride(from: 0, to: width, by: c) {
                // A frame is not a whole number of cells, so the right and bottom edges are
                // partial: clipping the average AND the blit is what stops a cell hanging off the
                // edge from reading or writing another row's pixels.
                let endY = min(cellY + c, height), endX = min(cellX + c, width)
                var sum = 0, count = 0
                for y in cellY..<endY { for x in cellX..<endX {
                    sum += Int(pixels[y * width + x]); count += 1
                } }
                let avg = count > 0 ? sum / count : 0
                let glyphIndex = (255 - avg) * span / 255
                let bitmap = atlas.bitmaps[min(max(0, glyphIndex), atlas.bitmaps.count - 1)]
                for y in cellY..<endY {
                    let row = (y - cellY) * c
                    for x in cellX..<endX {
                        output[y * width + x] = 255 &- bitmap[row + (x - cellX)]
                    }
                }
            }
        }
        return applyPaletteAndBackground(output, settings: settings)
    }

    /// The atlas for one glyph set at one cell, rasterized on first use and kept. Never evicted:
    /// an atlas is at most `glyphs.count * cellSize²` bytes — under 3 KB for the largest cell the
    /// settings panel offers — over a key space of two bundled sets crossed with the sizes a user
    /// picks, so bounding it would cost more code than the memory it could reclaim.
    private func atlas(for set: ASCIIGlyphSet, cellSize: Int) -> GlyphAtlas {
        let key = AtlasKey(set: set, cellSize: cellSize)
        if let cached = atlases[key] { return cached }
        let built = GlyphAtlas(set: set, cellSize: cellSize)
        atlases[key] = built
        return built
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