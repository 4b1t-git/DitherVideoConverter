import CryptoKit
import XCTest
@testable import AnciiVideoGenerator

final class RenderingParityTests: XCTestCase {
    private let gradient: [UInt8] = (0..<64).map { UInt8($0 * 4) }
    private let blackWhite: [SRGBColor] = [SRGBColor(r: 0, g: 0, b: 0), SRGBColor(r: 255, g: 255, b: 255)]

    func testRenderSettingsIsImmutableSendableAndEquatable() throws {
        let palette = try Palette(colors: blackWhite)
        let dither = try RenderSettings(style: .dither(.threshold), palette: palette)
        let ascii = try RenderSettings(style: .ascii(.numeric), palette: palette, cellSize: 4)
        XCTAssertEqual(dither, dither)
        XCTAssertNotEqual(dither, ascii)
        let _: any Sendable = dither
        let _: any Sendable = ascii
    }

    func testPaletteSizeTwoThroughSixteenAcceptedAndOthersRejectStatingTwoToSixteen() {
        XCTAssertNoThrow(try Palette(colors: Array(repeating: SRGBColor(r: 0, g: 0, b: 0), count: 2)))
        XCTAssertNoThrow(try Palette(colors: Array(repeating: SRGBColor(r: 0, g: 0, b: 0), count: 16)))
        assertPaletteRejected(count: 1)
        assertPaletteRejected(count: 17)
    }

    private func assertPaletteRejected(count: Int) {
        do {
            _ = try Palette(colors: Array(repeating: SRGBColor(r: 0, g: 0, b: 0), count: count))
            XCTFail("Palette with \(count) colors must be rejected")
        } catch RenderSettingsError.paletteSize(let received) {
            XCTAssertEqual(received, count)
            XCTAssertTrue(RenderSettingsError.paletteSize(received).errorDescription?.contains("2–16") == true,
                          "Palette rejection MUST state the '2–16' constraint")
        } catch let caught {
            XCTFail("Unexpected error type: \(caught)")
        }
    }

    func testEveryDitherModeRendersTwiceToTheSameReference() async throws {
        let palette = try Palette(colors: blackWhite)
        let renderer = MetalFrameRenderer()
        let request = RenderRequest(timestamp: 0, width: 8, height: 8, intent: .still, scale: 1)
        for mode in DitherMode.allCases {
            let settings = try RenderSettings(style: .dither(mode), palette: palette)
            let first = try await renderer.render(request: request, settings: settings,
                                                  pixels: gradient, sourceWidth: 8, sourceHeight: 8)
            let second = try await renderer.render(request: request, settings: settings,
                                                   pixels: gradient, sourceWidth: 8, sourceHeight: 8)
            XCTAssertEqual(first, second, "Dither mode \(mode) MUST render deterministically twice to the same reference")
            XCTAssertEqual(first.count, 64)
            print("DITHER_CONFORMANCE mode=\(mode) hash=\(SHA256.hash(data: Data(first)).map { String(format: "%02x", $0) }.joined())")
        }
    }

    // The asserted property is unchanged — a smaller cell MUST make the picture denser — but the
    // MEASUREMENT had to change. It used to sample each cell's CENTRE PIXEL and count the cells
    // whose centre came back dark, which was only meaningful because the implementation filled
    // every cell with one value: the centre stood in for the cell because the cell was uniform. It
    // measured an artefact of the mosaic, not a property of the output. With a real glyph, a cell
    // holding '.' has NO ink at its centre and ':' has ink only above and below it, so "is the
    // centre dark" now answers a question about where a character's strokes happen to fall.
    //
    // The honest generalisation is to stop sampling and count every dark pixel in the frame. Dark
    // still means what it meant before — the palette is [white, black], so byte 0 is index 0, the
    // white background, and anything else is ink — over all 256 pixels instead of one per cell.
    func testASCIIDensityIncreasesWhenCellSizeDecreases() async throws {
        let palette = try Palette(colors: [SRGBColor(r: 255, g: 255, b: 255), SRGBColor(r: 0, g: 0, b: 0)])
        let renderer = MetalFrameRenderer()
        let source = (0..<256).map { UInt8($0) }
        func density(cellSize: Int) async throws -> Int {
            let settings = try RenderSettings(style: .ascii(.text), palette: palette, cellSize: cellSize)
            let request = RenderRequest(timestamp: 0, width: 16, height: 16, intent: .still, scale: 1)
            let output = try await renderer.render(request: request, settings: settings,
                                                   pixels: source, sourceWidth: 16, sourceHeight: 16)
            return output.count { $0 != 0 }   // 0 = index 0 = the white background
        }
        let coarse = try await density(cellSize: 8)
        let fine = try await density(cellSize: 4)
        XCTAssertGreaterThan(fine, coarse,
                             "Smaller cell size MUST produce strictly greater density using only bundled glyphs/font "
                             + "(cell 4 inked \(fine) of 256 pixels, cell 8 inked \(coarse))")
    }

    // Glyph selection is what makes an ASCII render a picture rather than a texture: a brighter
    // cell MUST reach for a sparser character. Two brightnesses far enough apart to land on
    // different glyphs must therefore produce different PATTERNS, not merely different averages —
    // the mosaic also gave those cells different means, which is exactly why a mean comparison
    // could not detect this defect.
    func testTwoBrightnessesSelectDifferentGlyphsAndDrawDifferentPatterns() async throws {
        let palette = try Palette(colors: blackWhite)
        let renderer = MetalFrameRenderer()
        let cell = 8, width = 16, height = 8
        // Left half dark (dense glyph), right half light (sparse glyph).
        let source = (0..<(width * height)).map { UInt8($0 % width < 8 ? 20 : 220) }
        let settings = try RenderSettings(style: .ascii(.text), palette: palette,
                                          background: .postToneMapSDR, cellSize: cell)
        let request = RenderRequest(timestamp: 0, width: width, height: height, intent: .still, scale: 1)
        let output = try await renderer.render(request: request, settings: settings,
                                               pixels: source, sourceWidth: width, sourceHeight: height)
        let left = (0..<cell).flatMap { y in (0..<cell).map { x in output[y * width + x] } }
        let right = (0..<cell).flatMap { y in (cell..<(2 * cell)).map { x in output[y * width + x] } }
        XCTAssertNotEqual(left, right, "Two cells that select different glyphs MUST draw different pixels")
        // Compared as multisets too, so this fails if one cell is only a rearrangement of the other.
        XCTAssertNotEqual(left.sorted(), right.sorted(),
                          "The two cells MUST differ in their ink, not only in where the ink sits")
        XCTAssertGreaterThan(left.reduce(0) { $0 + (255 - Int($1)) }, right.reduce(0) { $0 + (255 - Int($1)) },
                             "Inverse density: the DARKER source cell MUST carry the denser character")
    }

    // Harness, not a gate: it reports what a full-resolution ASCII frame costs here so the Metal-port
    // decision comes from measurement, with a dither frame beside it as the reference point (dither
    // already holds 30 fps). It asserts nothing about time — a timing assertion on a shared machine
    // fails for reasons that have nothing to do with this code.
    func testASCIIFullResolutionThroughputHarness() async throws {
        let palette = try Palette(colors: blackWhite)
        let renderer = MetalFrameRenderer()
        let width = 1_920, height = 1_080
        let source = (0..<(width * height)).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }
        let request = RenderRequest(timestamp: 0, width: width, height: height, intent: .export, scale: 1)
        func report(_ label: String, _ settings: RenderSettings) async throws {
            // Warm-up first: the opening ASCII frame at a new cell size also pays to rasterize the
            // atlas, and billing that one-off cost per frame would overstate an export's real cost.
            _ = try await renderer.render(request: request, settings: settings,
                                          pixels: source, sourceWidth: width, sourceHeight: height)
            let start = ContinuousClock.now
            let output = try await renderer.render(request: request, settings: settings,
                                                   pixels: source, sourceWidth: width, sourceHeight: height)
            let elapsed = start.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            XCTAssertEqual(output.count, width * height, "\(label) MUST still produce one byte per oriented pixel")
            print("ASCII_THROUGHPUT style=\(label) width=\(width) height=\(height) "
                  + "elapsed=\(String(format: "%.6f", seconds)) fps=\(String(format: "%.2f", 1 / max(seconds, 1e-9)))")
        }
        for cell in [4, 8, 16] {
            try await report("ascii-text-cell\(cell)", try RenderSettings(style: .ascii(.text), palette: palette, cellSize: cell))
        }
        try await report("dither-bayer", try RenderSettings(style: .dither(.bayer), palette: palette))
    }

    // `GlyphAtlas` is the rasterization the renderer had no access to: one coverage bitmap per
    // glyph, laid out like a cell, so `asciiStylize` can blit a character instead of inventing a
    // brightness from its index. The blit indexes by that shape, so shape is checked before ink.
    // Determinism rides along: the renderer caches one atlas per (set, cell) and every cell of a
    // frame reads it, so a rasterizer that varied would make two renders of one frame differ by
    // when the cache happened to be built — what
    // `testEveryDitherModeRendersTwiceToTheSameReference` pins for the dither modes.
    func testGlyphAtlasRasterizesOneCellSizedBitmapPerGlyphOfTheSet() {
        for set in ASCIIGlyphSet.allCases { for cellSize in [1, 4, 8, 16] {
            let atlas = GlyphAtlas(set: set, cellSize: cellSize)
            XCTAssertEqual(atlas.cellSize, cellSize, "The atlas MUST report the cell it rasterized for")
            XCTAssertEqual(atlas.bitmaps.count, set.glyphs.count,
                           "\(set.rawValue) at cell \(cellSize) MUST carry one bitmap per bundled glyph")
            XCTAssertEqual(atlas.bitmaps.map(\.count), Array(repeating: cellSize * cellSize, count: set.glyphs.count),
                           "Every \(set.rawValue) glyph MUST cover exactly one \(cellSize)×\(cellSize) cell")
            XCTAssertEqual(atlas.bitmaps, GlyphAtlas(set: set, cellSize: cellSize).bitmaps,
                           "Rasterizing \(set.rawValue) at cell \(cellSize) twice MUST give identical coverage")
        } }
    }

    // Coverage, not colour: a value is how much of the pixel the character covers, so `asciiStylize`
    // alone decides whether ink reads dark or light. The space glyph is the proof — the mapping
    // picks it for a fully bright cell, so it MUST be empty at every palette, background and cell.
    func testTextGlyphSetRastersSpaceAsEmptyAndItsDensestGlyphAsRealInk() {
        for cellSize in [4, 8, 16] {
            let ink = GlyphAtlas(set: .text, cellSize: cellSize).bitmaps.map { $0.reduce(0) { $0 + Int($1) } }
            XCTAssertEqual(ink[0], 0, "The space glyph MUST rasterize to zero ink at cell \(cellSize)")
            XCTAssertGreaterThan(ink[ink.count - 1], 0,
                                 "The densest glyph MUST rasterize to strictly positive ink at cell \(cellSize)")
            XCTAssertEqual(ink.firstIndex(of: ink.min()!), 0, "No glyph may carry less ink than the space glyph")
        }
    }

    // `asciiStylize` maps a cell average to a slot with `(255 - avg) * span / 255`, so it is correct
    // only while slot 0 holds the LIGHTEST glyph and the last slot the densest. Declaration order
    // does not deliver that: measured against Menlo `.text` inverts locally (':' out-inks '-', '#'
    // out-inks both '%' and '@') and `.numeric` inverts outright, '0' being the densest digit while
    // it is declared first.
    //
    // This asserted the weaker property the declared `.text` order happened to satisfy — every glyph
    // of the dense half out-inking every glyph of the sparse half — because a monotone ramp would
    // have asserted something the font does not do. `GlyphAtlas` now sorts its own entries by
    // MEASURED coverage, so the font no longer decides: the full property holds for BOTH sets at
    // every cell, and asserting the half-split instead would leave `.numeric`'s inversion, the one
    // the sort exists to remove, invisible.
    func testGlyphAtlasOrdersEverySetsBitmapsByMeasuredInkAscending() {
        for set in ASCIIGlyphSet.allCases { for cellSize in [4, 8, 16] {
            let ink = GlyphAtlas(set: set, cellSize: cellSize).bitmaps.map { $0.reduce(0) { $0 + Int($1) } }
            XCTAssertTrue(zip(ink, ink.dropFirst()).allSatisfy { $0 <= $1 },
                          "At cell \(cellSize) the \(set.rawValue) atlas MUST run lightest slot first — "
                          + "`asciiStylize` sends the brightest cell to slot 0; ink=\(ink)")
        } }
    }

    // The inversion stated at its sharpest, and kept out of the monotone check so it cannot be lost
    // in a list of ten numbers: '0' is Menlo's densest digit and `ASCIIGlyphSet.numeric` declares it
    // first, so the slot reserved for the BRIGHTEST cell carried the darkest character.
    func testNumericGlyphSetLeavesItsLightestGlyphInTheSlotTheBrightestCellSelects() {
        for cellSize in [4, 8, 16] {
            let ink = GlyphAtlas(set: .numeric, cellSize: cellSize).bitmaps.map { $0.reduce(0) { $0 + Int($1) } }
            XCTAssertLessThan(ink[0], ink[ink.count - 1],
                              "At cell \(cellSize) the numeric set's first slot MUST carry strictly less ink than "
                              + "its last; first=\(ink[0]) last=\(ink[ink.count - 1])")
        }
    }

    // Sorting reorders a set; it must never edit one. The atlas publishes the characters in the order
    // it settled on, so the ramp is inspectable rather than inferred from byte counts, and this pins
    // that order to a PERMUTATION of the declared set — every bundled glyph still present, exactly
    // once, none invented. `GlyphCatalog.txt` and its drift test own WHICH glyphs a set contains;
    // this owns the fact that sorting leaves that membership alone.
    func testGlyphAtlasPublishesItsGlyphsAsAPermutationOfTheDeclaredSet() {
        for set in ASCIIGlyphSet.allCases { for cellSize in [1, 4, 8, 16] {
            let atlas = GlyphAtlas(set: set, cellSize: cellSize)
            XCTAssertEqual(atlas.glyphs.count, atlas.bitmaps.count,
                           "\(set.rawValue) at cell \(cellSize) MUST name one glyph per bitmap")
            XCTAssertEqual(atlas.glyphs.sorted(), set.glyphs.sorted(),
                           "Sorting \(set.rawValue) by ink at cell \(cellSize) MUST reorder the bundled glyphs, "
                           + "never lose, duplicate or invent one; got \(atlas.glyphs)")
        } }
    }

    // Ties are the only place a sort can be non-deterministic, and this codebase cannot afford one:
    // the renderer caches an atlas per (set, cell) and every cell of every frame reads it, so an
    // order that varied would make two runs of one export differ. `bitmaps` determinism is already
    // pinned above; the published order needs the same guarantee, or the ramp could be stable in
    // pixels and unstable in what it claims to be.
    func testGlyphAtlasSortsToTheSameOrderEveryTime() {
        for set in ASCIIGlyphSet.allCases { for cellSize in [1, 4, 8, 16] {
            let first = GlyphAtlas(set: set, cellSize: cellSize)
            let second = GlyphAtlas(set: set, cellSize: cellSize)
            XCTAssertEqual(first.bitmaps, second.bitmaps,
                           "Two \(set.rawValue) atlases at cell \(cellSize) MUST hold identical coverage")
            XCTAssertEqual(first.glyphs, second.glyphs,
                           "Two \(set.rawValue) atlases at cell \(cellSize) MUST settle on the identical glyph "
                           + "order; \(first.glyphs) vs \(second.glyphs)")
        } }
    }

    // The same defect in rendered pixels rather than atlas bytes, which is where a user meets it: a
    // BRIGHT region of a `.numeric` render came out darker than a dark one. `.postToneMapSDR` keeps
    // the byte a stylized brightness, so ink is `255 - byte` with no palette in between.
    func testNumericASCIIDrawsABrightCellWithStrictlyLessInkThanADarkOne() async throws {
        let palette = try Palette(colors: blackWhite)
        let renderer = MetalFrameRenderer()
        let cell = 8, width = 16, height = 8
        let source = (0..<(width * height)).map { UInt8($0 % width < cell ? 235 : 20) }
        let settings = try RenderSettings(style: .ascii(.numeric), palette: palette,
                                          background: .postToneMapSDR, cellSize: cell)
        let request = RenderRequest(timestamp: 0, width: width, height: height, intent: .still, scale: 1)
        let output = try await renderer.render(request: request, settings: settings,
                                               pixels: source, sourceWidth: width, sourceHeight: height)
        func ink(columns: Range<Int>) -> Int {
            (0..<height).reduce(0) { total, y in
                total + columns.reduce(0) { $0 + (255 - Int(output[y * width + $1])) }
            }
        }
        let bright = ink(columns: 0..<cell), dark = ink(columns: cell..<(2 * cell))
        XCTAssertLessThan(bright, dark,
                          "A bright numeric cell MUST draw strictly less ink than a dark one; "
                          + "bright=\(bright) dark=\(dark). More ink on the bright cell IS the inverted ramp — "
                          + "'0' is the densest digit and it sits in the slot the brightest cell selects.")
    }

    // `RenderSettings` rejects a cell size below 1 and `RenderSettings.make` clamps one, so the
    // renderer never asks — but the atlas allocates a `cellSize × cellSize` buffer and sizes a font
    // from it, and both trap on a non-positive number. Clamping keeps a future caller's mistake a
    // wrong picture rather than a crash.
    func testGlyphAtlasClampsANonPositiveCellSizeInsteadOfTrapping() {
        for rejected in [0, -1, -16] {
            let atlas = GlyphAtlas(set: .text, cellSize: rejected)
            XCTAssertEqual(atlas.cellSize, 1, "Cell size \(rejected) MUST clamp to the smallest legal cell")
            XCTAssertEqual(atlas.bitmaps.map(\.count), Array(repeating: 1, count: ASCIIGlyphSet.text.glyphs.count),
                           "A clamped atlas MUST still carry every glyph, each one pixel rather than zero")
        }
    }

    // The defect this slice fixes: `asciiStylize` chose a glyph from the cell average, then threw
    // it away and filled the whole cell with one brightness derived from the glyph's INDEX. The
    // output was a mosaic — ASCII in name only — and nothing in the suite could tell, because every
    // check only ever compared one cell against another.
    //
    // A rasterized glyph is by definition ink in some pixels of the cell and background in the
    // rest, so the smallest honest statement of "a character was drawn" is that ONE cell holds more
    // than one distinct value. Under `.postToneMapSDR` the byte IS the stylized brightness, so this
    // reads the glyph's own coverage with no palette in the way.
    func testASCIICellCarriesGlyphShapeRatherThanOneUniformFill() async throws {
        let palette = try Palette(colors: blackWhite)
        let renderer = MetalFrameRenderer()
        let cell = 8, width = 32, height = 32
        // A diagonal ramp: every cell averages to a different brightness, so every cell selects a
        // glyph and none of them is the empty space glyph by accident.
        let source = (0..<(width * height)).map { UInt8(truncatingIfNeeded: 30 + ($0 % width) * 3 + ($0 / width) * 3) }
        let settings = try RenderSettings(style: .ascii(.text), palette: palette,
                                          background: .postToneMapSDR, cellSize: cell)
        let request = RenderRequest(timestamp: 0, width: width, height: height, intent: .still, scale: 1)
        let output = try await renderer.render(request: request, settings: settings,
                                               pixels: source, sourceWidth: width, sourceHeight: height)
        let origins = stride(from: 0, to: height, by: cell).flatMap { y in
            stride(from: 0, to: width, by: cell).map { (y, $0) }
        }
        let shapedCells = origins.count { cellY, cellX in
            Set((cellY..<(cellY + cell)).flatMap { y in (cellX..<(cellX + cell)).map { output[y * width + $0] } }).count > 1
        }
        XCTAssertGreaterThan(shapedCells, 0,
                             "An ASCII cell MUST contain a rasterized glyph — ink in some pixels and background in "
                             + "the rest. A cell of one repeated value is the mosaic this replaced, not a character.")
        XCTAssertEqual(shapedCells, (width / cell) * (height / cell),
                       "EVERY cell of a ramp that selects a non-empty glyph MUST carry that glyph's shape")
    }

    func testToneMapAppliedToHDRSourceBeforeStyling() async throws {
        let palette = try Palette(colors: blackWhite)
        let renderer = MetalFrameRenderer()
        let hdr = [UInt8](repeating: 255, count: 64)
        let request = RenderRequest(timestamp: 0, width: 8, height: 8, intent: .still, scale: 1)
        let tonemapped = try RenderSettings(style: .dither(.bayer), palette: palette, background: .postToneMapSDR, toneMap: true)
        let raw = try RenderSettings(style: .dither(.bayer), palette: palette, background: .postToneMapSDR, toneMap: false)
        let toneMappedResult = try await renderer.render(request: request, settings: tonemapped, pixels: hdr, sourceWidth: 8, sourceHeight: 8)
        let rawResult = try await renderer.render(request: request, settings: raw, pixels: hdr, sourceWidth: 8, sourceHeight: 8)
        XCTAssertEqual(rawResult, [UInt8](repeating: 255, count: 64), "Without tone-map, Bayer of bright HDR source stays full-bright")
        XCTAssertTrue(toneMappedResult.contains(0), "Tone-map MUST attenuate HDR-saturated input before styling, causing some Bayer cells to fall below threshold")
        XCTAssertNotEqual(toneMappedResult, rawResult, "Tone-map MUST change the stylized output")
    }

    // Issue #47. `asciiStylize` maps a cell average through `(255 - avg) * span / 255`, so the
    // DARKEST input takes the densest glyph — the print convention, where ink is laid on white
    // paper. Most ASCII-art footage is the opposite: a bright subject on a dark field, which under
    // that mapping gives every drop of ink to the background and leaves the subject blank.
    //
    // `invertSource` is the user-visible answer, and this is the property it exists for: with the
    // flag ON a BRIGHT cell must draw strictly MORE ink than a dark one — the exact inverse of the
    // default, asserted here in the same frame so neither reading can be a coincidence of the
    // fixture. `.postToneMapSDR` keeps the byte a stylized brightness, so ink is `255 - byte` with
    // no palette in between.
    func testInvertSourceMakesABrightASCIICellDrawStrictlyMoreInkThanADarkOne() async throws {
        let palette = try Palette(colors: blackWhite)
        let renderer = MetalFrameRenderer()
        let cell = 8, width = 16, height = 8
        // Left cell bright (235), right cell dark (20): one cell of each polarity, nothing else.
        let source = (0..<(width * height)).map { UInt8($0 % width < cell ? 235 : 20) }
        let request = RenderRequest(timestamp: 0, width: width, height: height, intent: .still, scale: 1)
        func ink(_ output: [UInt8], columns: Range<Int>) -> Int {
            (0..<height).reduce(0) { total, y in
                total + columns.reduce(0) { $0 + (255 - Int(output[y * width + $1])) }
            }
        }
        let printLike = try RenderSettings(style: .ascii(.text), palette: palette,
                                           background: .postToneMapSDR, cellSize: cell)
        let terminalLike = try RenderSettings(style: .ascii(.text), palette: palette,
                                              background: .postToneMapSDR, cellSize: cell,
                                              invertSource: true)
        let printed = try await renderer.render(request: request, settings: printLike,
                                                pixels: source, sourceWidth: width, sourceHeight: height)
        let inverted = try await renderer.render(request: request, settings: terminalLike,
                                                 pixels: source, sourceWidth: width, sourceHeight: height)
        let printedBright = ink(printed, columns: 0..<cell), printedDark = ink(printed, columns: cell..<(2 * cell))
        XCTAssertLessThan(printedBright, printedDark,
                          "Precondition: WITHOUT the flag the print convention MUST still hold — the dark cell "
                          + "takes the ink; bright=\(printedBright) dark=\(printedDark)")
        let invertedBright = ink(inverted, columns: 0..<cell), invertedDark = ink(inverted, columns: cell..<(2 * cell))
        XCTAssertGreaterThan(invertedBright, invertedDark,
                             "WITH invertSource a BRIGHT cell MUST draw strictly MORE ink than a dark one — that is "
                             + "the terminal convention the flag exists for; bright=\(invertedBright) "
                             + "dark=\(invertedDark). Ink still on the dark cell means the source was never inverted.")
    }

    // The regression guard that proves the flag is genuinely OPT-IN. `EXPORT_GOLDEN` pins one
    // dither render through the whole export path; this pins the renderer itself, for an ASCII and
    // a dither style, at the only place the flag could leak: settings that never mention it MUST
    // produce the identical bytes to settings that spell out `invertSource: false`, and both MUST
    // differ from the inverted render — otherwise the check would pass for a flag wired to nothing.
    func testInvertSourceDefaultsToFalseAndLeavesEveryStyleByteIdentical() async throws {
        let palette = try Palette(colors: blackWhite)
        let renderer = MetalFrameRenderer()
        let width = 32, height = 16
        let source = (0..<(width * height)).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 13) }
        let request = RenderRequest(timestamp: 0, width: width, height: height, intent: .still, scale: 1)
        for style in [RenderSettings.Style.ascii(.text), .dither(.bayer)] {
            let unmentioned = try RenderSettings(style: style, palette: palette,
                                                 background: .postToneMapSDR, cellSize: 4)
            XCTAssertFalse(unmentioned.invertSource,
                           "Settings that never mention \(style) inversion MUST default to the print convention")
            let explicit = try RenderSettings(style: style, palette: palette, background: .postToneMapSDR,
                                              cellSize: 4, invertSource: false)
            let flagged = try RenderSettings(style: style, palette: palette, background: .postToneMapSDR,
                                             cellSize: 4, invertSource: true)
            let baseline = try await renderer.render(request: request, settings: unmentioned,
                                                     pixels: source, sourceWidth: width, sourceHeight: height)
            let off = try await renderer.render(request: request, settings: explicit,
                                                pixels: source, sourceWidth: width, sourceHeight: height)
            let on = try await renderer.render(request: request, settings: flagged,
                                               pixels: source, sourceWidth: width, sourceHeight: height)
            XCTAssertEqual(baseline, off,
                           "`invertSource: false` MUST be byte-identical to omitting it for \(style); a flag that "
                           + "moves the default output is not opt-in and would move every pinned golden with it")
            XCTAssertNotEqual(baseline, on,
                              "`invertSource: true` MUST change \(style)'s output — equality here would mean the "
                              + "byte-identity above is vacuous because the flag is wired to nothing")
        }
    }

    // Threshold is the mode whose result can be stated exactly, which is why the deterministic
    // proof lives here: every pixel of the source is above 128, so WITHOUT the flag every pixel is
    // 255, and inverting the source puts every pixel below 128, so every pixel is 0. Nothing about
    // that depends on a glyph raster, a palette, or a matrix — the two outputs are complements.
    func testInvertSourceFlipsAThresholdDitherOfAUniformlyBrightSource() async throws {
        let palette = try Palette(colors: blackWhite)
        let renderer = MetalFrameRenderer()
        let source = [UInt8](repeating: 200, count: 64)
        let request = RenderRequest(timestamp: 0, width: 8, height: 8, intent: .still, scale: 1)
        let upright = try RenderSettings(style: .dither(.threshold), palette: palette,
                                         background: .postToneMapSDR)
        let flipped = try RenderSettings(style: .dither(.threshold), palette: palette,
                                         background: .postToneMapSDR, invertSource: true)
        let plain = try await renderer.render(request: request, settings: upright,
                                              pixels: source, sourceWidth: 8, sourceHeight: 8)
        let inverted = try await renderer.render(request: request, settings: flipped,
                                                 pixels: source, sourceWidth: 8, sourceHeight: 8)
        XCTAssertEqual(Set(plain), [255],
                       "Precondition: 200 is above the 128 threshold, so the upright render MUST be solid white")
        XCTAssertEqual(Set(inverted), [0],
                       "Inverting a source of 200 gives 55, which is BELOW the threshold, so the render MUST be "
                       + "solid black — the exact complement of the upright one")
    }

    // The ordering `invertSource` and `toneMap` are applied in is a real decision, not an
    // implementation detail: tone mapping is a non-linear PQ→SDR transfer, so inverting before it
    // and inverting after it give different pictures. The renderer inverts the RAW SOURCE FIRST,
    // and this pins that choice so it cannot change silently.
    //
    // WHY that order: `toneMap` is strongly convex — its own pinned goldens (0→0, 64→3, 128→34,
    // 192→112, 255→235) put more than half of the input range below 34. Inverting AFTERWARDS maps
    // that crushed range onto 255…221, so roughly half of every tone-mapped frame would land in the
    // sparsest glyph slot and the picture would go blank again — the very defect this flag exists
    // to fix. Measured over all 256 input values, tone-map-then-invert puts 121 of them in glyph
    // slot 0 and never reaches the densest slot at all, while invert-then-tone-map spreads across
    // all ten slots and reproduces the tone map's calibrated 0…235 output range instead of pushing
    // values back above the display clip the roll-off deliberately stays under.
    //
    // 64 is chosen because the two orders land on OPPOSITE sides of the threshold, so a mode with
    // no shades of grey can tell them apart.
    func testInvertSourceIsAppliedToTheRawSourceBeforeToneMapping() async throws {
        XCTAssertEqual(MetalFrameRenderer.toneMap(191), 111,
                       "Precondition: inverting first hands the tone map 191, which lands BELOW the threshold")
        XCTAssertEqual(255 &- MetalFrameRenderer.toneMap(64), 252,
                       "Precondition: inverting last would give 252, ABOVE the threshold — the orders genuinely differ")
        XCTAssertEqual(MetalFrameRenderer.toneMap(64), 3,
                       "Precondition: NOT inverting leaves the tone map 3 — glyph slot 8, nearly the densest")
        XCTAssertEqual(MetalFrameRenderer.toneMap(191), 111,
                       "Precondition: inverting FIRST hands the tone map 191, which becomes 111 — a mid glyph")
        XCTAssertEqual(255 &- MetalFrameRenderer.toneMap(64), 252,
                       "Precondition: inverting LAST would give 252 — glyph slot 0, the empty one. The three "
                       + "readings are far enough apart that ink alone tells them apart.")
        let palette = try Palette(colors: blackWhite)
        let renderer = MetalFrameRenderer()
        let cell = 8
        let source = [UInt8](repeating: 64, count: cell * cell)
        let request = RenderRequest(timestamp: 0, width: cell, height: cell, intent: .still, scale: 1)
        func ink(_ output: [UInt8]) -> Int { output.reduce(0) { $0 + (255 - Int($1)) } }
        let upright = try RenderSettings(style: .ascii(.text), palette: palette,
                                         background: .postToneMapSDR, cellSize: cell, toneMap: true)
        let flipped = try RenderSettings(style: .ascii(.text), palette: palette,
                                         background: .postToneMapSDR, cellSize: cell, toneMap: true,
                                         invertSource: true)
        let uprightInk = ink(try await renderer.render(request: request, settings: upright,
                                                       pixels: source, sourceWidth: cell, sourceHeight: cell))
        let flippedInk = ink(try await renderer.render(request: request, settings: flipped,
                                                       pixels: source, sourceWidth: cell, sourceHeight: cell))
        XCTAssertGreaterThan(flippedInk, 0,
                             "Inverting AFTER the tone map would give 252 and select the EMPTY glyph, drawing no "
                             + "ink at all. Ink here is what proves the inversion ran on the raw source instead.")
        XCTAssertLessThan(flippedInk, uprightInk,
                          "Inverting the raw source MUST move a tone-mapped frame off the dense end of the ramp: "
                          + "3 selects glyph 8, 111 selects glyph 5. Equal ink (\(flippedInk) vs \(uprightInk)) "
                          + "means the source was never inverted at all.")
    }

    func testPreEncodeStillEqualsExportAtOrientedResolution() async throws {
        let palette = try Palette(colors: blackWhite)
        let renderer = MetalFrameRenderer()
        let source = (0..<(64 * 36)).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 13) }
        let stillReq = RenderRequest(timestamp: 1_200, width: 64, height: 36, intent: .still, scale: 1)
        let exportReq = RenderRequest(timestamp: 1_200, width: 64, height: 36, intent: .export, scale: 1)
        for mode in DitherMode.allCases {
            let settings = try RenderSettings(style: .dither(mode), palette: palette)
            let still = try await renderer.render(request: stillReq, settings: settings, pixels: source, sourceWidth: 64, sourceHeight: 36)
            let exported = try await renderer.render(request: exportReq, settings: settings, pixels: source, sourceWidth: 64, sourceHeight: 36)
            XCTAssertEqual(still, exported, "Still and export MUST produce identical pre-encode pixels for mode \(mode)")
        }
    }

    func testFullResolutionStillRenderingThroughRendererAtSourceResolution() async throws {
        XCTAssertEqual(sysctlString("machdep.cpu.brand_string"), "Apple M5")
        let palette = try Palette(colors: blackWhite)
        let renderer = MetalFrameRenderer()
        let width = 1_920, height = 1_080
        let source = (0..<(width * height)).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }
        let settings = try RenderSettings(style: .dither(.atkinson), palette: palette)
        let request = RenderRequest(timestamp: 0, width: width, height: height, intent: .still, scale: 1)
        let start = ContinuousClock.now
        let output = try await renderer.render(request: request, settings: settings, pixels: source, sourceWidth: width, sourceHeight: height)
        let elapsed = start.duration(to: .now)
        XCTAssertEqual(output.count, width * height, "Full-resolution still MUST produce one byte per oriented pixel")
        let hash = SHA256.hash(data: Data(output)).map { String(format: "%02x", $0) }.joined()
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("M5_ONLY harness=full-resolution-still width=\(width) height=\(height) pixels=\(output.count) elapsed=\(String(format: "%.6f", seconds)) hash=\(hash) model=\(sysctlString("hw.model")) scope=Apple-M5-only-not-M1-or-older")
    }

    // `MetalFrameRenderer.render` emits stylized BRIGHTNESS under `.postToneMapSDR`, so the byte is
    // already the grey level to paint. Anything else here would re-interpret a value the renderer
    // already resolved.
    func testDisplayColorUnderPostToneMapSDRIsTheByteAsGrey() throws {
        let settings = try RenderSettings(style: .dither(.bayer), palette: try Palette(colors: blackWhite),
                                          background: .postToneMapSDR)
        for byte in [UInt8(0), 1, 17, 128, 254, 255] {
            XCTAssertEqual(settings.displayColor(byte), SRGBColor(r: byte, g: byte, b: byte),
                           "Under .postToneMapSDR the byte IS brightness and MUST paint as that grey")
        }
    }

    // Under every background EXCEPT `.postToneMapSDR` the renderer's byte is a palette INDEX
    // (0…N-1). Painting it as grey is what made the black/white backgrounds render index 0 and 1 as
    // two indistinguishable shades of black; the index MUST resolve through the palette instead.
    func testDisplayColorUnderBlackOnWhiteResolvesPaletteIndices() throws {
        let settings = try RenderSettings(style: .dither(.bayer), palette: try Palette(colors: blackWhite),
                                          background: .blackOnWhite)
        XCTAssertEqual(settings.displayColor(0), SRGBColor(r: 0, g: 0, b: 0),
                       "Index 0 MUST resolve to the palette's first colour, not to grey 0")
        XCTAssertEqual(settings.displayColor(1), SRGBColor(r: 255, g: 255, b: 255),
                       "Index 1 MUST resolve to the palette's second colour, not to grey 1")
    }

    // The check that proves colour palettes work AT ALL: a 4-colour sepia set MUST come back as
    // sepia. A grey reading of the same indices produces {0, 1, 2, 3} — four shades of black.
    func testDisplayColorResolvesEveryEntryOfAFourColourPalette() throws {
        let sepia = [SRGBColor(r: 0, g: 0, b: 0), SRGBColor(r: 80, g: 40, b: 20),
                     SRGBColor(r: 180, g: 130, b: 80), SRGBColor(r: 250, g: 240, b: 210)]
        for background in [RenderBackground.blackOnWhite, .whiteOnBlack] {
            let settings = try RenderSettings(style: .dither(.bayer), palette: try Palette(colors: sepia),
                                              background: background)
            for (index, expected) in sepia.enumerated() {
                XCTAssertEqual(settings.displayColor(UInt8(index)), expected,
                               "Index \(index) under \(background) MUST paint as the palette's own sRGB colour")
            }
        }
    }

    // Unreachable through `Palette.nearest`, which only ever returns an in-range index. The mapping
    // still MUST NOT trap: it runs once per pixel, so an out-of-range byte from a future renderer
    // change has to degrade to the grey reading rather than take the whole app down.
    func testDisplayColorFallsBackToGreyForAnOutOfRangePaletteIndex() throws {
        let settings = try RenderSettings(style: .dither(.bayer), palette: try Palette(colors: blackWhite),
                                          background: .blackOnWhite)
        XCTAssertEqual(settings.displayColor(200), SRGBColor(r: 200, g: 200, b: 200),
                       "A byte past the palette's last index MUST fall back to grey instead of trapping")
    }

    // The three palettes the app ships MUST all reach a picker, in the order the file lists them:
    // the file IS the catalogue the user chooses from, so a load that silently drops or reorders
    // entries is a UI defect nobody would trace back to a decoder.
    func testBundledCatalogLoadsEveryShippedPaletteInFileOrder() throws {
        let catalog = PaletteCatalog.bundled()
        XCTAssertEqual(catalog.map(\.name), ["Black on White", "White on Black", "Sepia 4"],
                       "Every shipped palette MUST load, in the order BundledPalettes.json lists them")
        // Sepia is the entry that proves COLOUR palettes survive the decode: the other two are
        // black/white pairs, which a decoder that lost every component but the first would still
        // reproduce correctly by accident.
        let sepia = try XCTUnwrap(catalog.last)
        XCTAssertEqual(sepia.palette.colors,
                       [SRGBColor(r: 0, g: 0, b: 0), SRGBColor(r: 80, g: 40, b: 20),
                        SRGBColor(r: 180, g: 130, b: 80), SRGBColor(r: 250, g: 240, b: 210)],
                       "Sepia 4 MUST decode to its four exact sRGB triples")
    }

    // A picker bound to an empty list offers the user nothing and cannot be recovered from inside
    // the app. Missing resource, unreadable file, or unusable content MUST therefore all degrade to
    // one built-in palette rather than to nothing.
    func testMissingCatalogResourceYieldsTheFallbackPaletteAndNeverAnEmptyList() {
        // The test bundle's own resources build phase is empty, so it genuinely lacks the JSON —
        // an unreadable-resource case produced by the build, not simulated by a stub.
        let bundle = Bundle(for: RenderingParityTests.self)
        XCTAssertNil(bundle.url(forResource: "BundledPalettes", withExtension: "json"),
                     "Precondition: the test bundle MUST NOT ship the catalogue")
        let catalog = PaletteCatalog.bundled(in: bundle)
        XCTAssertFalse(catalog.isEmpty, "A palette list MUST never be empty; an empty picker is worse than a short one")
        XCTAssertEqual(catalog, [PaletteCatalog.fallback],
                       "A missing catalogue MUST degrade to exactly the built-in fallback palette")
    }

    // `Resources/Fonts/GlyphCatalog.txt` and `ASCIIGlyphSet` state the SAME two glyph rows in two
    // places, and nothing reads the file — the enum is the renderer's only source. Writing a parser
    // for it would add code to obtain what the enum already provides; the real risk is that someone
    // edits one of the two and ships a catalogue that no longer describes what the app draws. This
    // check costs nothing and makes that drift loud.
    func testBundledGlyphCatalogAgreesWithTheASCIIGlyphSetEnum() throws {
        // `Bundle.main` IS the host app bundle here: every test target sets TEST_HOST to the app,
        // and the app is the only target whose resources phase carries the catalogue.
        let url = try XCTUnwrap(Bundle.main.url(forResource: "GlyphCatalog", withExtension: "txt"),
                                "GlyphCatalog.txt MUST ship in the host app bundle")
        let catalog = try String(contentsOf: url, encoding: .utf8)
        for set in ASCIIGlyphSet.allCases {
            let prefix = "\(set.rawValue):"
            let row = try XCTUnwrap(catalog.split(separator: "\n").first { $0.hasPrefix(prefix) },
                                    "The catalogue MUST carry a '\(prefix)' row")
            XCTAssertEqual(glyphs(inCatalogRow: String(row.dropFirst(prefix.count))), set.glyphs,
                           "The bundled catalogue's \(set.rawValue) row MUST match ASCIIGlyphSet.\(set.rawValue)")
        }
    }

    /// Splits one catalogue row into glyphs: whitespace separates entries, and a double-quoted entry
    /// (how the catalogue writes the space glyph, which is otherwise indistinguishable from a
    /// separator) yields whatever it wraps.
    private func glyphs(inCatalogRow row: String) -> [String] {
        var glyphs: [String] = []
        var quoted: String?
        for character in row {
            if let current = quoted {
                if character == "\"" { glyphs.append(current); quoted = nil } else { quoted = current + String(character) }
            } else if character == "\"" {
                quoted = ""
            } else if !character.isWhitespace {
                glyphs.append(String(character))
            }
        }
        return glyphs
    }

    // A picker cannot enumerate `RenderSettings.Style` — it carries associated values and is not
    // `CaseIterable` — so the settings panel offers `RenderStyleOption` instead. The list it offers
    // MUST be the complete set of styles the renderer implements: a missing case is a style the
    // spec requires the app to offer and the user can never reach.
    func testRenderStyleOptionOffersEveryDitherModeThenEveryGlyphSet() {
        XCTAssertEqual(RenderStyleOption.allCases.count, DitherMode.allCases.count + ASCIIGlyphSet.allCases.count,
                       "The picker MUST offer every dither mode and every bundled glyph set, and nothing else")
        for (index, mode) in DitherMode.allCases.enumerated() {
            XCTAssertEqual(RenderStyleOption.allCases[index], .dither(mode),
                           "Dither modes MUST come first, in DitherMode.allCases order")
            XCTAssertEqual(RenderStyleOption.allCases[index].style, .dither(mode),
                           "Option .dither(\(mode)) MUST map to the matching renderer style")
        }
        for (offset, set) in ASCIIGlyphSet.allCases.enumerated() {
            let index = DitherMode.allCases.count + offset
            XCTAssertEqual(RenderStyleOption.allCases[index], .ascii(set),
                           "Glyph sets MUST follow the dither modes, in ASCIIGlyphSet.allCases order")
            XCTAssertEqual(RenderStyleOption.allCases[index].style, .ascii(set),
                           "Option .ascii(\(set.rawValue)) MUST map to the matching renderer style")
        }
        XCTAssertEqual(Set(RenderStyleOption.allCases.map(\.description)).count, RenderStyleOption.allCases.count,
                       "Two options sharing a label would be indistinguishable in the picker")
    }

    // The panel derives its selection FROM the coordinator's settings and writes it back through
    // the same type, so the trip out and back MUST be lossless: a lossy round trip would silently
    // reset the user's style the first time the panel re-read it.
    func testRenderStyleOptionRoundTripsEveryStyleThroughItsRendererForm() {
        for option in RenderStyleOption.allCases {
            XCTAssertEqual(RenderStyleOption(option.style), option,
                           "\(option) MUST survive the trip through RenderSettings.Style and back")
        }
    }

    // The background picker enumerates the same way, so `RenderBackground` MUST be `CaseIterable`
    // and every case MUST carry a label a user can tell apart from the other two.
    func testRenderBackgroundOffersAllThreeWithDistinctNonEmptyLabels() {
        XCTAssertEqual(RenderBackground.allCases, [.blackOnWhite, .whiteOnBlack, .postToneMapSDR],
                       "The picker MUST offer all three backgrounds the renderer implements")
        for background in RenderBackground.allCases {
            XCTAssertFalse(background.description.isEmpty, "\(background) MUST carry a picker label")
        }
        XCTAssertEqual(Set(RenderBackground.allCases.map(\.description)).count, RenderBackground.allCases.count,
                       "Two backgrounds sharing a label would be indistinguishable in the picker")
    }

    // `RenderSettings.make` is the ONE place picker state becomes settings, and it MUST be total:
    // a control that can produce a configuration the initializer rejects would either trap or
    // silently do nothing, and the user would have no way to tell which. Clamping the cell size is
    // what removes the only throwing condition, so `make` never has an error to hide.
    func testRenderSettingsMakeClampsNonPositiveCellSizeAndPreservesEverythingElse() throws {
        let palette = try Palette(colors: blackWhite)
        for rejected in [0, -1, Int.min + 1] {
            let settings = RenderSettings.make(style: .ascii(.text), palette: palette,
                                               background: .whiteOnBlack, cellSize: rejected, toneMap: true)
            XCTAssertEqual(settings.cellSize, 1, "Cell size \(rejected) MUST clamp to the smallest legal cell")
            XCTAssertEqual(settings.style, .ascii(.text), "Clamping MUST NOT change the chosen style")
            XCTAssertEqual(settings.palette, palette, "Clamping MUST NOT change the chosen palette")
            XCTAssertEqual(settings.background, .whiteOnBlack, "Clamping MUST NOT change the chosen background")
            XCTAssertTrue(settings.toneMap, "Clamping MUST NOT change the tone-map choice")
        }
        let kept = RenderSettings.make(style: .dither(.atkinson), palette: palette,
                                       background: .postToneMapSDR, cellSize: 7, toneMap: false)
        XCTAssertEqual(kept.cellSize, 7, "A legal cell size MUST be carried through unchanged")
        XCTAssertEqual(kept.style, .dither(.atkinson), "The assembled settings MUST carry the chosen style")
        XCTAssertEqual(kept.background, .postToneMapSDR, "The assembled settings MUST carry the chosen background")
        XCTAssertFalse(kept.toneMap, "The assembled settings MUST carry the tone-map choice")
    }

    private func sysctlString(_ key: String) -> String {
        var size = 0; sysctlbyname(key, nil, &size, nil, 0)
        var value = [CChar](repeating: 0, count: size); sysctlbyname(key, &value, &size, nil, 0)
        return String(cString: value)
    }
}