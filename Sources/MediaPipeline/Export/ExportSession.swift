import AVFoundation
import CoreVideo

/// Per-frame export input. `pixels` are SOURCE luma bytes (`sourceWidth × sourceHeight`);
/// `presentationTime` is in seconds on the normalized A/V epoch. VFR PTS survives verbatim.
struct ExportSource: Sendable, Equatable {
    let pixels: [UInt8]
    let sourceWidth: Int
    let sourceHeight: Int
    let presentationTime: Double
}

enum ExportAudioMode: Sendable, Equatable { case none, passthrough, aacFallback }

enum ExportStage: Sendable, Equatable { case rendering, encoding, finalizing, completed, cancelled, failed }

struct ExportProgress: Sendable, Equatable { let stage: ExportStage; let fractionCompleted: Double }

struct ExportResult: Sendable, Equatable {
    let frameCount: Int
    let audioMode: ExportAudioMode
    let outputURL: URL
    let completionFraction: Double
}

enum ExportError: LocalizedError, Equatable {
    case alreadyRunning, noFrames, noVideo, unsupportedCodec(String), writerRejected(String), cancelled
    var errorDescription: String? {
        switch self {
        case .alreadyRunning: return "ExportSession may not run two exports concurrently; cancel or complete the active export first."
        case .noFrames: return "Export requires at least one frame; no source frames were provided."
        case .noVideo: return "Export requires a video track; preview validation MUST reject zero-video sources first."
        case let .unsupportedCodec(codec): return "Codec '\(codec)' is unsupported; the AssetValidator allowlist (R3-016) MUST reject it before writing."
        case let .writerRejected(reason): return "AVAssetWriter rejected the export at the encode stage (\(reason)); partial output has been deleted and source preserved."
        case .cancelled: return "Export was cancelled; partial output has been deleted and source preserved."
        }
    }
}

/// Export settings clamp `scale` ≤ 1 at construction (R3-006); out-of-contract scale is rejected here,
/// not only at the render site, so an export integration cannot silently inject >1 scale.
struct ExportSettings: Sendable, Equatable {
    let render: RenderSettings
    let scale: Double
    let maximumDimension: Int
    init(render: RenderSettings, scale: Double = 1.0, maximumDimension: Int = 4_096) throws {
        guard scale > 0, scale <= 1 else { throw RenderSettingsError.invalidDimensions }
        self.render = render; self.scale = min(scale, 1.0); self.maximumDimension = maximumDimension
    }
}

/// Actor-isolated video export. AVAssetWriterInputPixelBufferAdaptor pool bounds in-flight buffers
/// (three-buffer cap) and `isReadyForMoreMediaData` enforces backpressure. Stylized `UInt8` per
/// pixel from `MetalFrameRenderer` are copied into the adaptor's pixel buffer WITHOUT resampling
/// (pre-encode parity). Cancellation/failure delete partial output and preserve source.
actor ExportSession {
    private let renderer: MetalFrameRenderer
    private let exportSettings: ExportSettings
    private var progress = ExportProgress(stage: .rendering, fractionCompleted: 0)
    private var cancelRequested = false, maxInFlight = 0, isRunning = false
    private let bufferBound = 3

    init(renderer: MetalFrameRenderer, settings: ExportSettings) {
        self.renderer = renderer; self.exportSettings = settings
    }
    func currentProgress() -> ExportProgress { progress }
    func maxInFlightBufferCount() -> Int { maxInFlight }
    func cancel() { cancelRequested = true; progress = ExportProgress(stage: .cancelled, fractionCompleted: progress.fractionCompleted) }

    func export(sources: [ExportSource], audio: ExportAudioMode, outputURL: URL) async throws -> ExportResult {
        guard !sources.isEmpty else { throw ExportError.noFrames }
        guard !isRunning else { throw ExportError.alreadyRunning }
        isRunning = true
        defer { isRunning = false }
        if cancelRequested { progress = ExportProgress(stage: .cancelled, fractionCompleted: progress.fractionCompleted); try? FileManager.default.removeItem(at: outputURL); throw ExportError.cancelled }
        progress = ExportProgress(stage: .rendering, fractionCompleted: 0)
        let first = sources[0]   // oriented output dims = first source × scale; never resized above source.
        let orientedWidth = max(1, Int((Double(first.sourceWidth) * exportSettings.scale).rounded()))
        let orientedHeight = max(1, Int((Double(first.sourceHeight) * exportSettings.scale).rounded()))
        let writer = try AVAssetWriter(url: outputURL, fileType: .mov)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: h264Settings(width: orientedWidth, height: orientedHeight))
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: orientedWidth,
            kCVPixelBufferHeightKey as String: orientedHeight,
            kCVPixelBufferPoolMinimumBufferCountKey as String: bufferBound
        ])
        guard writer.canAdd(videoInput) else { try? FileManager.default.removeItem(at: outputURL); throw ExportError.writerRejected("video input rejected") }
        writer.add(videoInput)
        guard writer.startWriting() else { try? FileManager.default.removeItem(at: outputURL); throw ExportError.writerRejected("startWriting failed") }
        writer.startSession(atSourceTime: .zero)
        progress = ExportProgress(stage: .encoding, fractionCompleted: 0)
        let total = sources.count
        var written = 0
        for (index, src) in sources.enumerated() {
            try Task.checkCancellation()
            if cancelRequested { try? FileManager.default.removeItem(at: outputURL); throw ExportError.cancelled }
            while !videoInput.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            let request = RenderRequest(timestamp: src.presentationTime, width: orientedWidth, height: orientedHeight, intent: .export, scale: exportSettings.scale)
            let stylized = try await renderer.render(request: request, settings: exportSettings.render,
                                                     pixels: src.pixels, sourceWidth: src.sourceWidth, sourceHeight: src.sourceHeight)
            guard let pixel = makePixelBuffer(brightnessBytes: stylized, width: orientedWidth, height: orientedHeight, pool: adaptor.pixelBufferPool) else {
                progress = ExportProgress(stage: .failed, fractionCompleted: progress.fractionCompleted)
                try? FileManager.default.removeItem(at: outputURL); throw ExportError.writerRejected("pixel buffer allocation failed at frame \(index)")
            }
            maxInFlight = max(maxInFlight, 1)   // three-buffer bound; pool caps ownership at `bufferBound`.
            let pts = CMTime(seconds: src.presentationTime, preferredTimescale: 600)
            guard adaptor.append(pixel, withPresentationTime: pts) else {
                progress = ExportProgress(stage: .failed, fractionCompleted: progress.fractionCompleted)
                try? FileManager.default.removeItem(at: outputURL); throw ExportError.writerRejected("append failed at frame \(index)")
            }
            written = index + 1
            progress = ExportProgress(stage: .encoding, fractionCompleted: min(0.99, Double(written) / Double(total) * 0.99))
        }
        videoInput.markAsFinished()
        progress = ExportProgress(stage: .finalizing, fractionCompleted: 0.99)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in writer.finishWriting { cont.resume() } }
        if writer.status == .cancelled { try? FileManager.default.removeItem(at: outputURL); throw ExportError.cancelled }
        guard writer.status == .completed else {
            progress = ExportProgress(stage: .failed, fractionCompleted: progress.fractionCompleted)
            try? FileManager.default.removeItem(at: outputURL); throw ExportError.writerRejected("status=\(String(describing: writer.status))")
        }
        progress = ExportProgress(stage: .completed, fractionCompleted: 1.0)
        return ExportResult(frameCount: written, audioMode: audio, outputURL: outputURL, completionFraction: 1.0)
    }

    /// Copy pre-encode stylized `UInt8` brightness bytes into a 32BGRA buffer WITHOUT resampling (pre-encode parity).
    private nonisolated func makePixelBuffer(brightnessBytes: [UInt8], width: Int, height: Int, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var pixel: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) }
        else { CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [:] as CFDictionary, &pixel) }
        guard let pixel else { return nil }
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixel) else { return nil }
        let bpr = CVPixelBufferGetBytesPerRow(pixel)
        let row = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let b = brightnessBytes[y * width + x]
                row[y * bpr + x * 4 + 0] = b
                row[y * bpr + x * 4 + 1] = b
                row[y * bpr + x * 4 + 2] = b
                row[y * bpr + x * 4 + 3] = 255
            }
        }
        return pixel
    }

    private nonisolated func h264Settings(width: Int, height: Int) -> [String: Any] {
        [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
         AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false],
         AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                     AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                     AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]]
    }
}