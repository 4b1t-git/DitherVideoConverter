import AVFoundation
import CoreGraphics

/// Asset validation per `interactive-video-preview`: local, unprotected, AVFoundation-readable,
/// exactly one enabled video track and zero/one audio track. Unsupported inputs report an
/// actionable reason; the source is never resized or mutated.
enum AssetValidationError: LocalizedError, Equatable {
    case streaming, protected, zeroVideo, multipleVideo, multipleAudio, nonfiniteDimensions, overflowDimensions
    case unreadable(String), unsupportedCodec(String), unsupportedDimensions(width: Int, height: Int)

    var errorDescription: String? {
        switch self {
        case .streaming: return "Streaming sources are unsupported; choose a local file."
        case .protected: return "Protected content is unsupported; choose an unprotected source."
        case .zeroVideo: return "Source has no enabled video track; exactly one video track is required."
        case .multipleVideo: return "Source has multiple video tracks; exactly one is required."
        case .multipleAudio: return "Source has multiple audio tracks; at most one audio track is supported."
        case let .unreadable(reason): return "Source is unreadable (\(reason)); choose an unprotected local AVFoundation-readable file."
        case let .unsupportedCodec(codec): return "Codec '\(codec)' is unsupported; use H.264 or HEVC."
        case let .unsupportedDimensions(width, height): return "Oriented dimensions \(width)×\(height) exceed the supported maximum; source MUST NOT be resized."
        case .nonfiniteDimensions: return "Source dimensions must be finite; nonfinite metadata is unsupported."
        case .overflowDimensions: return "Source dimensions overflow compute bounds; source MUST NOT be resized."
        }
    }
}

struct AssetValidationReport: Sendable, Equatable {
    let isSupported: Bool
    let violation: AssetValidationError?
    let orientedWidth: Int
    let orientedHeight: Int
    let sourceUnchanged: Bool
    let summary: String
}

enum AssetValidator {
    static func validate(_ asset: AVAsset, maximumDimension: Int) async -> AssetValidationReport {
        if asset.hasProtectedContent { return unsupported(.protected) }
        if let url = asset as? AVURLAsset, let scheme = url.url.scheme, scheme != "file" {
            return unsupported(.streaming)
        }
        let videoTracks: [AVAssetTrack], audioTracks: [AVAssetTrack]
        do {
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch { return unsupported(.unreadable(String(describing: error))) }
        if videoTracks.isEmpty { return unsupported(.zeroVideo) }
        if videoTracks.count > 1 { return unsupported(.multipleVideo) }
        if audioTracks.count > 1 { return unsupported(.multipleAudio) }
        let video = videoTracks[0]
        do {
            let format = try await video.load(.formatDescriptions).first
            guard let format else { return unsupported(.unreadable("missing video format description")) }
            let coded = CMVideoFormatDescriptionGetDimensions(format)
            let natural = CGSize(width: Int(coded.width), height: Int(coded.height))
            let transform = try await video.load(.preferredTransform)
            let oriented = try orientedDimensions(naturalSize: natural, preferredTransform: transform,
                                                  maximumDimension: maximumDimension)
            return AssetValidationReport(isSupported: true, violation: nil,
                                          orientedWidth: oriented.width, orientedHeight: oriented.height,
                                          sourceUnchanged: true,
                                          summary: "Supported: \(oriented.width)×\(oriented.height) oriented, 1 video, \(audioTracks.count) audio.")
        } catch let violation as AssetValidationError { return unsupported(violation) }
        catch { return unsupported(.unreadable(String(describing: error))) }
    }

    /// Pure, overflow-aware oriented-dimension computation. Rejects nonfinite metadata and
    /// dimension multiplication that overflows `Int64` before any maximum-dimension check,
    /// mirroring `GeometryPlan`'s transform convention without resizing.
    static func orientedDimensions(naturalSize: CGSize, preferredTransform: CGAffineTransform,
                                   maximumDimension: Int) throws -> (width: Int, height: Int) {
        guard naturalSize.width.isFinite, naturalSize.height.isFinite else { throw AssetValidationError.nonfiniteDimensions }
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform).standardized.size
        guard oriented.width.isFinite, oriented.height.isFinite else { throw AssetValidationError.nonfiniteDimensions }
        guard oriented.width <= Double(Int.max), oriented.height <= Double(Int.max) else { throw AssetValidationError.overflowDimensions }
        let width = max(0, Int(oriented.width.rounded())), height = max(0, Int(oriented.height.rounded()))
        let area = Int64(width).multipliedReportingOverflow(by: Int64(height))
        guard !area.overflow else { throw AssetValidationError.overflowDimensions }
        guard width <= maximumDimension, height <= maximumDimension else {
            throw AssetValidationError.unsupportedDimensions(width: width, height: height)
        }
        return (width, height)
    }

    private static func unsupported(_ violation: AssetValidationError) -> AssetValidationReport {
        AssetValidationReport(isSupported: false, violation: violation, orientedWidth: 0, orientedHeight: 0,
                              sourceUnchanged: true, summary: violation.errorDescription ?? "")
    }
}