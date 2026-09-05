import Foundation
import CoreGraphics

enum DitherMode: UInt32, CaseIterable, Sendable, Equatable, CustomStringConvertible {
    case threshold, bayer, atkinson, floydSteinberg
    var description: String {
        switch self {
        case .threshold: return "threshold"
        case .bayer: return "bayer"
        case .atkinson: return "atkinson"
        case .floydSteinberg: return "floyd-steinberg"
        }
    }
}

/// Bundled ASCII glyph sets. Custom fonts/glyphs MUST NOT be accepted (per spec).
enum ASCIIGlyphSet: String, CaseIterable, Sendable, Equatable {
    case numeric, text
    var glyphs: [String] {
        switch self {
        case .numeric: return ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
        case .text: return [" ", ".", ":", "-", "+", "*", "o", "#", "%", "@"]
        }
    }
}

enum RenderBackground: Sendable, Equatable { case blackOnWhite, whiteOnBlack, postToneMapSDR }
enum RenderIntent: Sendable, Equatable { case preview, still, export }

/// sRGB color triple, the only palette entry type. Custom palettes MUST use 2–16 colors.
struct SRGBColor: Sendable, Equatable {
    let r: UInt8, g: UInt8, b: UInt8
    init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }
    /// Convert to linear RGB via the inverse sRGB gamma approximation.
    func linear() -> (Double, Double, Double) {
        func convert(_ c: UInt8) -> Double {
            let v = Double(c) / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return (convert(r), convert(g), convert(b))
    }
}

enum RenderSettingsError: LocalizedError, Equatable {
    case paletteSize(Int)
    case invalidCellSize(Int)
    case invalidDimensions
    var errorDescription: String? {
        switch self {
        case let .paletteSize(n): return "Custom palette MUST contain 2–16 sRGB colors; received \(n)."
        case let .invalidCellSize(n): return "ASCII cell size MUST be ≥1; received \(n)."
        case .invalidDimensions: return "Render request dimensions MUST be positive."
        }
    }
}

/// Immutable palette that precomputes linear RGB at construction time.
/// Nearest matching is always in linear RGB space (per spec).
struct Palette: Sendable, Equatable {
    let colors: [SRGBColor]
    private let linearRGB: [Double]   // flat r, g, b per color, length 3N

    init(colors: [SRGBColor]) throws {
        guard colors.count >= 2, colors.count <= 16 else {
            throw RenderSettingsError.paletteSize(colors.count)
        }
        self.colors = colors
        self.linearRGB = colors.flatMap { let l = $0.linear(); return [l.0, l.1, l.2] }
    }

    /// Returns the palette index (as UInt8) nearest to a grayscale brightness in linear RGB.
    func nearest(toBrightness value: UInt8) -> UInt8 {
        let target = SRGBColor(r: value, g: value, b: value).linear()
        var bestIndex = 0, bestDistance = Double.infinity
        for index in colors.indices {
            let r = linearRGB[index * 3], g = linearRGB[index * 3 + 1], b = linearRGB[index * 3 + 2]
            let dr = target.0 - r, dg = target.1 - g, db = target.2 - b
            let distance = dr * dr + dg * dg + db * db
            if distance < bestDistance { bestDistance = distance; bestIndex = index }
        }
        return UInt8(bestIndex)
    }
}

/// Immutable rendering settings shared by preview, still, and export (per spec).
/// All fields are `let`; construction enforces 2–16 palette colors and cell size ≥1.
struct RenderSettings: Sendable, Equatable {
    enum Style: Sendable, Equatable { case dither(DitherMode), ascii(ASCIIGlyphSet) }
    let style: Style
    let palette: Palette
    let background: RenderBackground
    let cellSize: Int
    let toneMap: Bool

    init(style: Style, palette: Palette,
         background: RenderBackground = .blackOnWhite,
         cellSize: Int = 1, toneMap: Bool = false) throws {
        if case .ascii = style, cellSize < 1 { throw RenderSettingsError.invalidCellSize(cellSize) }
        self.style = style; self.palette = palette; self.background = background
        self.cellSize = cellSize; self.toneMap = toneMap
    }
}

/// Time + geometry + intent + scale for one request. Geometry MUST be oriented full
/// resolution for still/export; preview MAY lower resolution via `scale` only.
struct RenderRequest: Sendable, Equatable {
    let timestamp: Double
    let width: Int
    let height: Int
    let intent: RenderIntent
    let scale: Double
}

/// The single interpretation of ONE renderer output byte as a paintable sRGB color.
///
/// It lives on `RenderSettings`, not on the preview or on the export, because the byte means
/// nothing without the settings that produced it: `MetalFrameRenderer.render` emits stylized
/// BRIGHTNESS under `.postToneMapSDR` and a palette INDEX (0…N-1) under every other background.
/// Mapping an index back to a color is the painter's job, and there are two painters —
/// `PreviewSnapshot.makeImage` on screen and `ExportSession.makePixelBuffer` on the way to the
/// encoder. The spec's full-resolution parity requirement ("pre-encode pixels MUST match exactly")
/// makes two independent implementations a latent bug: they would agree the day they were written
/// and drift the first time only one of them was corrected, and the drift would only be visible to
/// someone comparing a still against a frame of the exported movie. So there is exactly one.
extension RenderSettings {
    func displayColor(_ byte: UInt8) -> SRGBColor {
        switch background {
        case .postToneMapSDR:
            // The byte already IS the brightness the style resolved; re-quantizing it here would
            // silently disagree with what the renderer decided.
            return SRGBColor(r: byte, g: byte, b: byte)
        case .blackOnWhite, .whiteOnBlack:
            let index = Int(byte)
            // Unreachable given the renderer's contract: `Palette.nearest` only ever returns an
            // index drawn from `colors.indices`. The guard exists so that a renderer change which
            // starts emitting something else DEGRADES to the grey reading instead of trapping —
            // this runs once per pixel, so an out-of-bounds subscript here would take the whole app
            // down mid-frame rather than show one wrong picture.
            guard palette.colors.indices.contains(index) else {
                return SRGBColor(r: byte, g: byte, b: byte)
            }
            return palette.colors[index]
        }
    }
}
