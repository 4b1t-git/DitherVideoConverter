import AppKit
import CoreGraphics
import CoreText
import Foundation

/// One bundled glyph set rasterized once, at one cell size, as coverage bitmaps.
///
/// The piece `MetalFrameRenderer.asciiStylize` was missing. It chose a glyph from a cell's average
/// brightness, then turned that glyph's INDEX straight back into a uniform brightness — so
/// `ASCIIGlyphSet.glyphs` was read for `.count` alone, the character was picked and discarded, and
/// the output was a mosaic. An atlas turns the chosen index into pixels the renderer can blit.
///
/// ## Coverage, not colour
///
/// A byte is INK COVERAGE — 0 where the character misses the pixel, 255 where it covers it, the
/// antialiased fraction between. Deliberately NOT a brightness: whether ink reads dark-on-light or
/// light-on-dark belongs to `asciiStylize` and `applyPaletteAndBackground`, which own the palette
/// and background. A polarity baked in here would disagree with a `.whiteOnBlack` render, visible
/// only to someone comparing two backgrounds side by side.
///
/// ## The font is a system face, and that is a deviation
///
/// The spec asks for ONE bundled monospaced font. No font file is bundled — `Resources/Fonts/`
/// holds only `GlyphCatalog.txt` — and adding one is a licensing and asset decision, not something
/// to slip into a rendering bug fix. So this uses a face that ships with macOS, written down here
/// rather than hidden. The requirement the spec protects survives intact: the face is chosen HERE,
/// never by the user, and no custom font or glyph can reach the renderer. Menlo is preferred (on
/// every supported macOS, fixed-pitch, stable metrics); the fallbacks let a system without it draw
/// characters rather than an empty frame.
///
/// ## Determinism
///
/// Font smoothing and subpixel positioning are OFF: both make a glyph's pixels depend on where it
/// sits relative to the display and on user defaults, so two renders of one frame could differ.
/// Antialiasing stays ON — it is what gives a 4×4 cell a recognisable shape, and it is a
/// deterministic function of the outline. So one set at one cell always rasterizes to the same
/// bytes, which lets the renderer cache an atlas and reuse it for every cell.
struct GlyphAtlas: Sendable, Equatable {
    /// The cell this atlas was rasterized for, after clamping. Always ≥ 1.
    let cellSize: Int

    /// One `cellSize * cellSize` coverage bitmap per glyph, row-major from the top row down (the
    /// renderer's own pixel order), in the glyph set's order — sparsest first.
    let bitmaps: [[UInt8]]

    /// Rasterizes `set` at `cellSize`, which is clamped to at least 1 rather than rejected.
    /// `RenderSettings` already refuses a smaller one and `RenderSettings.make` clamps it, so the
    /// renderer cannot ask — but this allocates a `cellSize × cellSize` buffer and derives a point
    /// size from it, and both trap on a non-positive number. Clamping turns a future caller's
    /// mistake into one wrong-looking cell instead of a crash mid-frame.
    init(set: ASCIIGlyphSet, cellSize: Int) {
        let cell = max(1, cellSize)
        self.cellSize = cell
        let font = Self.face(size: Self.pointSize(fittingCell: cell))
        self.bitmaps = set.glyphs.map { Self.rasterize($0, font: font, cell: cell) }
    }

    /// Menlo, else the system monospaced face, else Monaco. `NSFont(name:size:)` returns `nil` for
    /// a face that is not installed, which is the only reason the fallbacks exist;
    /// `monospacedSystemFont` cannot fail, so the last step is unreachable in practice and written
    /// as a `??` chain rather than a branch needing a test that cannot be provoked.
    private static func face(size: CGFloat) -> CTFont {
        let font = NSFont(name: "Menlo", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            ?? NSFont(name: "Monaco", size: size)
        return (font ?? NSFont.systemFont(ofSize: size)) as CTFont
    }

    /// The largest point size whose advance width and cap height both fit the cell — derived, then
    /// verified. A monospaced advance is roughly 0.6 em and a cap height roughly 0.73 em, so
    /// `cell / 0.73` is the right neighbourhood; but "roughly" describes typefaces in general, not
    /// the one installed, so the estimate is measured against the REAL metrics and walked DOWN
    /// (never up) until both fit, which is what guarantees nothing overflows the cell.
    ///
    /// Cap height rather than ascent + descent: a monospaced ascender box is over a sixth taller
    /// than the capitals, and fitting THAT shrinks every glyph to about half the cell's width,
    /// leaving specks with barely distinguishable ink. These glyphs are punctuation, digits and
    /// lowercase letters with no descenders, so cap height bounds them — and `CGContext` clips
    /// whatever still reaches past the cell (`@` dips a fraction below the baseline).
    ///
    /// One size for the whole set, never one per glyph: a per-glyph fit would scale a period up
    /// until it filled the cell and destroy the density ramp the mapping needs.
    private static func pointSize(fittingCell cell: Int) -> CGFloat {
        let limit = CGFloat(cell)
        var size = max(1, (limit / 0.73).rounded(.down) + 2)   // start above the estimate, walk down
        while size > 1 {
            let font = face(size: size)
            if advanceWidth(of: font) <= limit && CTFontGetCapHeight(font) <= limit { return size }
            size -= 0.25
        }
        return 1
    }

    /// The set's shared advance, measured on a real glyph rather than read from the face's bounding
    /// box: that box covers every glyph in the font, while the advance is what actually governs how
    /// wide the rendered characters are.
    private static func advanceWidth(of font: CTFont) -> CGFloat {
        var characters: [UniChar] = Array("M".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count),
              let glyph = glyphs.first else { return .greatestFiniteMagnitude }
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, [glyph], &advance, 1)
        return advance.width
    }

    /// One glyph's coverage over one cell, centred. The buffer starts at 0 and the glyph is filled
    /// with 1.0 white, so the byte that comes back IS the coverage — no inversion, no palette. A
    /// LINEAR grey space makes an antialiased edge blend in coverage rather than gamma-encoded
    /// light: half a pixel of ink comes back as 128, not a perceptually-weighted value.
    ///
    /// Every failure path returns the zero buffer already allocated: an empty cell is an artefact a
    /// user can see and describe, and this runs inside a frame render, where throwing would take
    /// down a preview or an export over one unavailable glyph.
    private static func rasterize(_ glyph: String, font: CTFont, cell: Int) -> [UInt8] {
        var coverage = [UInt8](repeating: 0, count: cell * cell)
        guard let space = CGColorSpace(name: CGColorSpace.linearGray) else { return coverage }
        var characters: [UniChar] = Array(glyph.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count),
              var identifier = glyphs.first else { return coverage }
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, [identifier], &advance, 1)
        let capHeight = CTFontGetCapHeight(font)
        coverage.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  let context = CGContext(data: base, width: cell, height: cell, bitsPerComponent: 8,
                                          bytesPerRow: cell, space: space,
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            // Shape quality yes, display-dependent tricks no.
            context.setAllowsAntialiasing(true); context.setShouldAntialias(true)
            context.setAllowsFontSmoothing(false); context.setShouldSmoothFonts(false)
            context.setAllowsFontSubpixelPositioning(false); context.setShouldSubpixelPositionFonts(false)
            context.setAllowsFontSubpixelQuantization(false); context.setShouldSubpixelQuantizeFonts(false)
            context.setFillColor(gray: 1, alpha: 1)
            // Core Graphics' origin is bottom-left, so this centres the cap-height box vertically
            // and the advance horizontally. A monospaced glyph is symmetric about that box, so the
            // atlas lines up with the renderer's top-down rows without a flip.
            var origin = CGPoint(x: (CGFloat(cell) - advance.width) / 2,
                                 y: (CGFloat(cell) - capHeight) / 2)
            CTFontDrawGlyphs(font, &identifier, &origin, 1, context)
        }
        return coverage
    }
}
