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

    func testASCIIDensityIncreasesWhenCellSizeDecreases() async throws {
        let palette = try Palette(colors: [SRGBColor(r: 255, g: 255, b: 255), SRGBColor(r: 0, g: 0, b: 0)])
        let renderer = MetalFrameRenderer()
        let source = (0..<256).map { UInt8($0) }
        func density(cellSize: Int) async throws -> Int {
            let settings = try RenderSettings(style: .ascii(.text), palette: palette, cellSize: cellSize)
            let request = RenderRequest(timestamp: 0, width: 16, height: 16, intent: .still, scale: 1)
            let output = try await renderer.render(request: request, settings: settings,
                                                   pixels: source, sourceWidth: 16, sourceHeight: 16)
            let c = cellSize, cellsX = (16 + c - 1) / c, cellsY = (16 + c - 1) / c
            var darkCells = 0
            for cy in 0..<cellsY { for cx in 0..<cellsX {
                let px = min(cx * c + c / 2, 15), py = min(cy * c + c / 2, 15)
                if output[py * 16 + px] != 0 { darkCells += 1 }   // 0 = white background
            } }
            return darkCells
        }
        let coarse = try await density(cellSize: 8)
        let fine = try await density(cellSize: 4)
        XCTAssertGreaterThan(fine, coarse,
                             "Smaller cell size MUST produce strictly greater density using only bundled glyphs/font")
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

    private func sysctlString(_ key: String) -> String {
        var size = 0; sysctlbyname(key, nil, &size, nil, 0)
        var value = [CChar](repeating: 0, count: size); sysctlbyname(key, &value, &size, nil, 0)
        return String(cString: value)
    }
}