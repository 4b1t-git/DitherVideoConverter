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

enum RenderBackground: Sendable, Equatable, CaseIterable, CustomStringConvertible {
    case blackOnWhite, whiteOnBlack, postToneMapSDR
    /// Picker label. Kept short because it is read inside a control, not a sentence; the case name
    /// is the wrong thing to show a user and `String(describing:)` would otherwise show it.
    var description: String {
        switch self {
        case .blackOnWhite: return "Black on White"
        case .whiteOnBlack: return "White on Black"
        case .postToneMapSDR: return "Source (SDR)"
        }
    }
}
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

/// One entry of a palette picker: a `Palette` plus the name the catalogue gives it.
///
/// The name is NOT on `Palette` itself because a palette is a rendering input — it has to stay
/// comparable by colour alone, so two identically-coloured palettes loaded from different sources
/// still satisfy `RenderSettings`' equality. The name belongs to the catalogue that offers it.
struct NamedPalette: Sendable, Equatable {
    let name: String
    let palette: Palette
}

/// The palettes the app ships (`Resources/Palettes/BundledPalettes.json`), decoded into the model.
///
/// The file is the catalogue the user picks from, so this loader's only real requirement is that
/// it ALWAYS produces something to pick. Two consequences follow:
///
/// 1. A single unusable entry (a colour triple that is not a triple, or a colour count outside
///    `Palette`'s 2–16 range) is SKIPPED, not propagated. Failing the whole load over one bad
///    entry would cost the user every other palette in the file to punish a mistake in one of
///    them, and the mistake is in a resource they cannot edit.
/// 2. A missing, unreadable, or entirely unusable file degrades to `fallback` — never to `[]`. A
///    picker bound to an empty list offers nothing and cannot be recovered from inside the app,
///    which is a strictly worse failure than a picker that is missing one palette.
///
/// Skipped entries are dropped SILENTLY rather than logged. This type is in `RenderCore`, which
/// has no logging surface of its own, and the file it reads ships inside the app bundle: a user
/// can neither cause nor fix a malformed entry, so a log line would only ever be read by whoever
/// broke the resource — and `testBundledCatalogLoadsEveryShippedPaletteInFileOrder` already fails
/// loudly, at build time, for exactly that person.
enum PaletteCatalog {
    /// The catalogue's on-disk shape. `constraint` in the JSON is prose for a human reader and is
    /// deliberately not decoded: the 2–16 rule it states is enforced by `Palette.init`, and a
    /// second copy of it here could only drift from the one that actually runs.
    private struct Document: Decodable {
        struct Entry: Decodable {
            let name: String
            let colors: [[Int]]
        }
        let limitedPalettes: [Entry]
    }

    /// The palette a picker falls back to when the bundled catalogue yields nothing usable. Black
    /// and white, because it is the one pair every style renders meaningfully. The `try!` is safe
    /// by inspection: two colours is inside `Palette`'s 2–16 range.
    static let fallback: NamedPalette = {
        let palette = try! Palette(colors: [SRGBColor(r: 0, g: 0, b: 0), SRGBColor(r: 255, g: 255, b: 255)])
        return NamedPalette(name: "Black on White", palette: palette)
    }()

    /// Every usable palette in `bundle`'s catalogue, in the order the file lists them (the order is
    /// the picker's order, so it is preserved rather than sorted), or `[fallback]` when the file
    /// yields none.
    static func bundled(in bundle: Bundle = .main) -> [NamedPalette] {
        guard let url = bundle.url(forResource: "BundledPalettes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(Document.self, from: data) else {
            return [fallback]
        }
        let decoded = document.limitedPalettes.compactMap(namedPalette(from:))
        return decoded.isEmpty ? [fallback] : decoded
    }

    /// `nil` for an entry this loader cannot honour — a colour that is not an RGB triple, or a
    /// colour count `Palette` rejects. Both are skips, per the type's contract above.
    private static func namedPalette(from entry: Document.Entry) -> NamedPalette? {
        var colors: [SRGBColor] = []
        colors.reserveCapacity(entry.colors.count)
        for triple in entry.colors {
            guard triple.count == 3 else { return nil }
            colors.append(SRGBColor(r: component(triple[0]), g: component(triple[1]), b: component(triple[2])))
        }
        guard let palette = try? Palette(colors: colors) else { return nil }
        return NamedPalette(name: entry.name, palette: palette)
    }

    /// Clamps a JSON colour component into `0...255`. `UInt8(exactly:)` on an out-of-range value
    /// would trap, which would turn one typo in a shipped resource into a launch crash; clamping
    /// costs the entry its exact colour and nothing else.
    private static func component(_ value: Int) -> UInt8 {
        UInt8(min(255, max(0, value)))
    }
}

/// The flat, enumerable form of `RenderSettings.Style` that a picker can bind to.
///
/// It exists because `RenderSettings.Style` CANNOT be one: it carries associated values, so it is
/// not `CaseIterable` and a control has no way to list the six styles the renderer implements.
/// Making `Style` itself `CaseIterable` would mean inventing an `allCases` that names particular
/// dither modes and glyph sets inside the rendering model, where the choice belongs to the UI —
/// so the enumeration lives here, next to the picker's needs, and `style`/`init(_:)` keep the two
/// forms in lockstep.
enum RenderStyleOption: Hashable, Sendable, CaseIterable, CustomStringConvertible {
    case dither(DitherMode)
    case ascii(ASCIIGlyphSet)

    /// Every style the renderer implements, dither modes first. Derived from the two source enums
    /// rather than written out, so a new dither mode or glyph set reaches the picker automatically
    /// instead of being silently unreachable until someone remembers this list.
    static var allCases: [RenderStyleOption] {
        DitherMode.allCases.map(RenderStyleOption.dither) + ASCIIGlyphSet.allCases.map(RenderStyleOption.ascii)
    }

    init(_ style: RenderSettings.Style) {
        switch style {
        case let .dither(mode): self = .dither(mode)
        case let .ascii(set): self = .ascii(set)
        }
    }

    var style: RenderSettings.Style {
        switch self {
        case let .dither(mode): return .dither(mode)
        case let .ascii(set): return .ascii(set)
        }
    }

    /// Whether this style reads `RenderSettings.cellSize`. The cell-size control is gated on it:
    /// cell size is the ASCII inverse-density block and means nothing to a dither mode.
    var usesCellSize: Bool {
        if case .ascii = self { return true }
        return false
    }

    var description: String {
        switch self {
        case let .dither(mode): return "Dither · \(mode)"
        case let .ascii(set): return "ASCII · \(set.rawValue)"
        }
    }
}

/// Builds settings from picker state — the ONE place that conversion happens, so a control and an
/// export can never assemble the same choices differently.
extension RenderSettings {
    /// Total by construction: it never throws and never traps.
    ///
    /// `RenderSettings.init` has exactly one throwing condition — an ASCII style with a cell size
    /// below 1 — and clamping to `max(1, cellSize)` is what makes it unreachable. That clamp is
    /// what makes the `try!` honest rather than a bet: without it, a stepper that produced 0 would
    /// either take the app down or (if the throw were swallowed) leave the control visibly moved
    /// and nothing changed, which is the worse of the two because the user cannot see it happen.
    /// Clamping instead shows the cell size snapping back to 1, which is the truth.
    static func make(style: RenderStyleOption, palette: Palette,
                     background: RenderBackground, cellSize: Int, toneMap: Bool) -> RenderSettings {
        try! RenderSettings(style: style.style, palette: palette, background: background,
                            cellSize: max(1, cellSize), toneMap: toneMap)
    }
}
