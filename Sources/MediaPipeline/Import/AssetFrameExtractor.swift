import AVFoundation
import CoreVideo

/// `import-asset-frames` (H3). Errors raised by `AssetFrameExtractor.extract`.
enum AssetImportError: LocalizedError, Equatable {
    /// The in-memory frame guard (`AssetFrameExtractor.maximumFrameCount`) was exceeded;
    /// extraction was cancelled before decoding the whole asset into memory.
    case frameLimitExceeded(Int)
    /// The asset (or a specific sample within it) could not be read.
    case unreadable(String)
    /// The asset has no video track to extract frames from.
    case noVideoTrack

    var errorDescription: String? {
        switch self {
        case let .frameLimitExceeded(limit):
            return "Import exceeded the \(limit)-frame in-memory guard; extraction was cancelled."
        case let .unreadable(reason):
            return "Asset frames are unreadable (\(reason))."
        case .noVideoTrack:
            return "Asset has no enabled video track to extract frames from."
        }
    }
}

/// Pure coded→oriented luma permutation (D3, LOCKED). Applies the track's `preferredTransform`
/// to the coded rect, `.standardized`, and corrects by `(-minX, -minY)` so the oriented rect's
/// origin is `(0, 0)`. Each CODED pixel is forward-mapped by its pixel CENTER — `(x + 0.5, y +
/// 0.5)`, never the integer corner — because forward-mapping a corner is off-by-half-a-pixel
/// under a rotation and silently misaligns every row for 90°/270° transforms. The result is
/// floored and clamped into the oriented bounds (clamping only guards floating-point rounding at
/// the oriented edge; every interior coded pixel maps to a distinct oriented pixel for the
/// 0/90/180/270 + flip cases this project supports, so no oriented pixel is left unwritten).
struct OrientedLumaMap {
    let codedWidth: Int
    let codedHeight: Int
    let orientedWidth: Int
    let orientedHeight: Int

    private let transform: CGAffineTransform
    private let correctionX: Double
    private let correctionY: Double

    init(codedWidth: Int, codedHeight: Int, preferredTransform: CGAffineTransform) {
        self.codedWidth = codedWidth
        self.codedHeight = codedHeight
        self.transform = preferredTransform
        let standardized = CGRect(x: 0, y: 0, width: CGFloat(codedWidth), height: CGFloat(codedHeight))
            .applying(preferredTransform).standardized
        self.correctionX = -Double(standardized.minX)
        self.correctionY = -Double(standardized.minY)
        self.orientedWidth = max(1, Int(standardized.width.rounded()))
        self.orientedHeight = max(1, Int(standardized.height.rounded()))
    }

    /// Permutes a tightly-packed, row-major coded luma buffer (`codedWidth`×`codedHeight`) into
    /// a tightly-packed, row-major oriented luma buffer (`orientedWidth`×`orientedHeight`).
    /// `coded.count` MUST be `>= codedWidth * codedHeight`; excess trailing bytes are ignored.
    func permute(_ coded: [UInt8]) -> [UInt8] {
        var oriented = [UInt8](repeating: 0, count: orientedWidth * orientedHeight)
        for y in 0..<codedHeight {
            for x in 0..<codedWidth {
                let center = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5).applying(transform)
                let destX = Int(floor(Double(center.x) + correctionX))
                let destY = Int(floor(Double(center.y) + correctionY))
                let clampedX = min(max(destX, 0), orientedWidth - 1)
                let clampedY = min(max(destY, 0), orientedHeight - 1)
                oriented[clampedY * orientedWidth + clampedX] = coded[y * codedWidth + x]
            }
        }
        return oriented
    }
}

/// Decodes a real video file into oriented `[ExportSource]` (H3, `import-asset-frames`).
/// Reads the Y-plane luma of each sample via `AVAssetReader`, permutes it from CODED to
/// ORIENTED space through `OrientedLumaMap`, and stamps each source's `presentationTime` with
/// the sample's real PTS — never an index-derived value, which is what preserves VFR spacing.
enum AssetFrameExtractor {
    /// In-memory guard: `[ExportSource]` holds every decoded frame at once (no streaming export
    /// yet), so an unbounded asset could exhaust memory. 1 800 frames is generous for the
    /// interactive-preview use case this project targets while still bounding worst case.
    static let maximumFrameCount = 1_800

    static func extract(from asset: AVAsset, maximumDimension: Int) async throws -> [ExportSource] {
        let videoTracks = try await loadVideoTracks(asset)
        guard let track = videoTracks.first else { throw AssetImportError.noVideoTrack }
        guard let format = try await track.load(.formatDescriptions).first else {
            throw AssetImportError.unreadable("missing video format description")
        }
        let coded = CMVideoFormatDescriptionGetDimensions(format)
        let codedWidth = Int(coded.width), codedHeight = Int(coded.height)
        let transform = try await track.load(.preferredTransform)

        // Dimension authority: the SAME pure function AssetValidator uses, so
        // ExportSource.sourceWidth/Height equal AssetValidator's oriented report by construction.
        let oriented: (width: Int, height: Int)
        do {
            oriented = try AssetValidator.orientedDimensions(
                naturalSize: CGSize(width: codedWidth, height: codedHeight),
                preferredTransform: transform, maximumDimension: maximumDimension)
        } catch let violation as AssetValidationError {
            throw AssetImportError.unreadable(violation.errorDescription ?? String(describing: violation))
        }

        let map = OrientedLumaMap(codedWidth: codedWidth, codedHeight: codedHeight, preferredTransform: transform)
        let reader = try makeReader(asset: asset, track: track)

        var sources: [ExportSource] = []
        while let sample = reader.output.copyNextSampleBuffer() {
            if sources.count >= maximumFrameCount {
                reader.reader.cancelReading()
                throw AssetImportError.frameLimitExceeded(maximumFrameCount)
            }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let orientedPixels = map.permute(copyLumaPlane(pixelBuffer, codedWidth: codedWidth, codedHeight: codedHeight))
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            sources.append(ExportSource(pixels: orientedPixels, sourceWidth: oriented.width,
                                        sourceHeight: oriented.height, presentationTime: CMTimeGetSeconds(pts)))
        }
        guard reader.reader.status == .completed else {
            let reason = reader.reader.error.map { String(describing: $0) } ?? "status=\(reader.reader.status.rawValue)"
            throw AssetImportError.unreadable(reason)
        }
        return sources
    }

    private static func loadVideoTracks(_ asset: AVAsset) async throws -> [AVAssetTrack] {
        do { return try await asset.loadTracks(withMediaType: .video) }
        catch { throw AssetImportError.unreadable(String(describing: error)) }
    }

    /// `AVAssetReader` construction and `startReading()` both throw/return failure synchronously
    /// on the calling thread — no suspension point exists to race, so this stays a plain factory.
    private static func makeReader(asset: AVAsset, track: AVAssetTrack) throws
        -> (reader: AVAssetReader, output: AVAssetReaderTrackOutput) {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw AssetImportError.unreadable(String(describing: error)) }
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AssetImportError.unreadable("reader cannot add video track output") }
        reader.add(output)
        guard reader.startReading() else {
            let reason = reader.error.map { String(describing: $0) } ?? "startReading failed"
            throw AssetImportError.unreadable(reason)
        }
        return (reader, output)
    }

    /// Copies plane 0 (luma) into a tightly-packed, row-major `codedWidth × codedHeight` buffer,
    /// honoring `bytesPerRow` (which may exceed `codedWidth` due to pixel-buffer row alignment).
    /// Copy bounds are clamped to `min(plane dimension, coded dimension)` so a decoder that
    /// reports slightly different plane dimensions than the track's format description (e.g.
    /// macroblock-aligned padding) can never read or write out of bounds; any uncovered trailing
    /// bytes stay zero-initialized.
    private static func copyLumaPlane(_ pixelBuffer: CVPixelBuffer, codedWidth: Int, codedHeight: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        var coded = [UInt8](repeating: 0, count: codedWidth * codedHeight)
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return coded }
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let planeWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let planeHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let copyWidth = min(planeWidth, codedWidth), copyHeight = min(planeHeight, codedHeight)
        let row = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<copyHeight {
            for x in 0..<copyWidth {
                coded[y * codedWidth + x] = row[y * bytesPerRow + x]
            }
        }
        return coded
    }
}
