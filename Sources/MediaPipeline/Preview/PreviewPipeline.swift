import CoreGraphics
import Foundation

/// One preview frame: the adapted `RenderRequest` (intent `.preview`, `scale` < 1) and the
/// renderer's stylized bytes at the lowered resolution. Preview, still, and export share the
/// sole `MetalFrameRenderer`; preview lowers resolution via `RenderRequest.scale` only.
struct PreviewSnapshot: Sendable, Equatable {
    let request: RenderRequest
    let pixels: [UInt8]
}

/// Bridges a snapshot's stylized luma bytes into a single 8-bit grayscale `CGImage`.
///
/// The preview surface used to fill one rounded rect per pixel inside a SwiftUI `Canvas`, which
/// costs O(W×H) draw calls per repaint: tolerable for a 16×8 fixture, unusable for a real clip.
/// One image handed to `Image(decorative:scale:)` collapses that to a single blit, and the
/// renderer's bytes stay the source of truth — no resampling, no re-quantization on the UI side.
///
/// Geometry comes from `request`, never from `pixels.count`: the request is what the renderer was
/// asked to produce, so a mismatch is a bug to surface as `nil`, not to paper over. Fails closed
/// (returns `nil`) on a non-positive size or a buffer shorter than `width * height`, because
/// handing CoreGraphics a short buffer would let it read past the end of the array.
extension PreviewSnapshot {
    func makeGrayscaleImage() -> CGImage? {
        let width = request.width, height = request.height
        guard width > 0, height > 0 else { return nil }
        let required = width * height
        guard pixels.count >= required else { return nil }
        // `Data(pixels.prefix(required))` COPIES the bytes into storage the provider owns. The
        // array must never be reached through an escaping unsafe pointer: `CGDataProvider` outlives
        // this call, and a pointer into `pixels` would dangle the moment the array is released.
        let copy = Data(pixels.prefix(required))
        guard let provider = CGDataProvider(data: copy as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}

/// Renderer seam for `PreviewPipeline`. `MetalFrameRenderer` conforms below; tests substitute a
/// controllable double to deterministically interleave concurrent scrub calls around the
/// renderer's `await` suspension point without sleeps or timing tolerances.
protocol FrameRendering: Sendable {
    func render(request: RenderRequest, settings: RenderSettings,
                pixels: [UInt8], sourceWidth: Int, sourceHeight: Int) async throws -> [UInt8]
}

extension MetalFrameRenderer: FrameRendering {}

/// Actor-isolated preview pipeline. Hysteresis changes only resolution (via `previewScale` or
/// `settings`); algorithms, glyphs, palettes, and anchoring are intent-invariant. Scrub
/// coalescing is zero-tolerance: a token not strictly newer than the last accepted token is
/// discarded both before any render work AND after the renderer's `await` suspends this actor,
/// so a stale scrub can never return a result even if it started before the token that
/// superseded it.
actor PreviewPipeline {
    private let renderer: any FrameRendering
    private var settings: RenderSettings
    private var previewScale: Double
    private var lastScrubToken: UInt64 = 0

    init(renderer: any FrameRendering, settings: RenderSettings, previewScale: Double) {
        self.renderer = renderer; self.settings = settings; self.previewScale = previewScale
    }

    func update(settings: RenderSettings) { self.settings = settings }
    func update(previewScale: Double) { self.previewScale = previewScale }

    func render(timestamp: Double, source: [UInt8], sourceWidth: Int, sourceHeight: Int) async throws -> PreviewSnapshot {
        let request = try makeRequest(timestamp: timestamp, sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        let pixels = try await renderer.render(request: request, settings: settings,
                                               pixels: source, sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        return PreviewSnapshot(request: request, pixels: pixels)
    }

    func scrub(token: UInt64, timestamp: Double, source: [UInt8], sourceWidth: Int, sourceHeight: Int) async throws -> PreviewSnapshot? {
        guard token > lastScrubToken else { return nil }
        lastScrubToken = token
        let snapshot = try await render(timestamp: timestamp, source: source, sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        // Re-validate AFTER the renderer's `await` suspends this actor: a newer scrub may have
        // advanced `lastScrubToken` while this call was suspended, in which case this result is
        // stale and MUST be dropped rather than returned as a valid snapshot.
        guard token == lastScrubToken else { return nil }
        return snapshot
    }

    private func makeRequest(timestamp: Double, sourceWidth: Int, sourceHeight: Int) throws -> RenderRequest {
        guard previewScale > 0, previewScale <= 1 else { throw RenderSettingsError.invalidDimensions }
        let scaledW = Double(sourceWidth) * previewScale, scaledH = Double(sourceHeight) * previewScale
        guard scaledW.isFinite, scaledH.isFinite,
              scaledW <= Double(Int.max), scaledH <= Double(Int.max) else { throw RenderSettingsError.invalidDimensions }
        let width = max(1, Int(scaledW.rounded())), height = max(1, Int(scaledH.rounded()))
        return RenderRequest(timestamp: timestamp, width: width, height: height, intent: .preview, scale: previewScale)
    }
}