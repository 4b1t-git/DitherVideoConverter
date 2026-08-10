import AVFoundation
import CoreVideo
@testable import AnciiVideoGenerator

struct MediaFixture { let videoURL: URL; let audioURL: URL; var urls: [URL] { [videoURL, audioURL] } }
struct MediaInspection {
    let video: [MediaSampleTiming]
    let audio: [MediaSampleTiming]
    let decodedVideoCount: Int
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
    let cleanAperture: CGRect
    let pixelAspectRatio: CGSize
    let colorPrimaries: String?
    let transferFunction: String?
    let yCbCrMatrix: String?
}
enum MediaFixtureError: Error { case setup(String), writing(Error?), reading }
final class MediaFixtureFactory {
    private let size = CGSize(width: 32, height: 16)

    func makeFixture() throws -> MediaFixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("unit-3-media-fixture-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        video.transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                          kCVPixelBufferWidthKey as String: Int(size.width),
                                          kCVPixelBufferHeightKey as String: Int(size.height)]
        )
        guard writer.canAdd(video) else { throw MediaFixtureError.setup("video input") }
        writer.add(video)
        guard writer.startWriting() else { throw MediaFixtureError.writing(writer.error) }
        writer.startSession(atSourceTime: .zero)
        for (index, pts) in [0, 24, 48, 72].enumerated() {
            while !video.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
            guard let pool = adaptor.pixelBufferPool else { throw MediaFixtureError.setup("pixel pool") }
            var pixel: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess,
                  let pixel else { throw MediaFixtureError.setup("pixel buffer") }
            CVPixelBufferLockBaseAddress(pixel, [])
            memset(CVPixelBufferGetBaseAddress(pixel), Int32(32 + index * 48), CVPixelBufferGetDataSize(pixel))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(pts), timescale: 600)) else {
                throw MediaFixtureError.writing(writer.error)
            }
        }
        video.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 120, timescale: 600))
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }; finished.wait()
        guard writer.status == .completed else { throw MediaFixtureError.writing(writer.error) }
        return MediaFixture(videoURL: url, audioURL: try makeAudioFixture())
    }
    func inspect(_ fixture: MediaFixture) async throws -> MediaInspection {
        let videoAsset = AVURLAsset(url: fixture.videoURL)
        let audioAsset = AVURLAsset(url: fixture.audioURL)
        guard let video = try await videoAsset.loadTracks(withMediaType: .video).first,
              let audio = try await audioAsset.loadTracks(withMediaType: .audio).first,
              let format = try await video.load(.formatDescriptions).first else {
            throw MediaFixtureError.reading
        }
        let composition = try makeComposition(video: video, audio: audio)
        guard let composedVideo = composition.tracks(withMediaType: .video).first,
              let composedAudio = composition.tracks(withMediaType: .audio).first else {
            throw MediaFixtureError.reading
        }
        let aperture = CMVideoFormatDescriptionGetCleanAperture(format, originIsAtTopLeft: true)
        let display = CMVideoFormatDescriptionGetPresentationDimensions(
            format, usePixelAspectRatio: true, useCleanAperture: true
        )
        let metadata = (CMFormatDescriptionGetExtensions(format) as NSDictionary?) ?? [:]
        let coded = CMVideoFormatDescriptionGetDimensions(format)
        return MediaInspection(
            video: segmentTiming(composedVideo), audio: segmentTiming(composedAudio),
            decodedVideoCount: try readCount(composedVideo, composition),
            naturalSize: CGSize(width: Int(coded.width), height: Int(coded.height)),
            preferredTransform: try await video.load(.preferredTransform), cleanAperture: aperture,
            pixelAspectRatio: CGSize(width: display.width / aperture.width, height: 1),
            colorPrimaries: metadata[kCMFormatDescriptionExtension_ColorPrimaries] as? String,
            transferFunction: metadata[kCMFormatDescriptionExtension_TransferFunction] as? String,
            yCbCrMatrix: metadata[kCMFormatDescriptionExtension_YCbCrMatrix] as? String
        )
    }
    private func makeComposition(video: AVAssetTrack, audio: AVAssetTrack) throws -> AVMutableComposition {
        let result = AVMutableComposition()
        guard let outputVideo = result.addMutableTrack(withMediaType: .video,
                                                        preferredTrackID: kCMPersistentTrackID_Invalid),
              let outputAudio = result.addMutableTrack(withMediaType: .audio,
                                                        preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MediaFixtureError.setup("composition tracks")
        }
        try outputAudio.insertTimeRange(CMTimeRange(start: .zero, duration: time(120)), of: audio, at: .zero)
        result.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: time(900)))
        result.insertEmptyTimeRange(CMTimeRange(start: result.duration, duration: time(180)))
        for (index, destination) in [(1_200, 24), (1_224, 48), (1_320, 24), (1_380, 60)].enumerated() {
            let target = time(Int64(destination.0))
            if CMTimeCompare(result.duration, target) < 0 {
                result.insertEmptyTimeRange(CMTimeRange(
                    start: result.duration, duration: CMTimeSubtract(target, result.duration)
                ))
            }
            let range = CMTimeRange(start: time(Int64(index * 24)), duration: time(24))
            try outputVideo.insertTimeRange(range, of: video, at: target)
            outputVideo.scaleTimeRange(CMTimeRange(start: target, duration: time(24)),
                                       toDuration: time(Int64(destination.1)))
        }
        outputVideo.preferredTransform = video.preferredTransform
        return result
    }
    private func segmentTiming(_ track: AVCompositionTrack) -> [MediaSampleTiming] {
        track.segments.filter { !$0.isEmpty }.map {
            MediaSampleTiming(presentationTime: $0.timeMapping.target.start,
                              duration: $0.timeMapping.target.duration)
        }
    }
    private func readCount(_ track: AVAssetTrack, _ asset: AVAsset) throws -> Int {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw MediaFixtureError.reading }
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0,
               CMTimeCompare(CMSampleBufferGetDuration(sample), .zero) > 0 { count += 1 }
        }
        guard reader.status == .completed else { throw MediaFixtureError.reading }
        return count
    }
    private var videoSettings: [String: Any] {
        [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: Int(size.width),
         AVVideoHeightKey: Int(size.height),
         AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false],
         AVVideoCleanApertureKey: [AVVideoCleanApertureWidthKey: 30, AVVideoCleanApertureHeightKey: 14,
                                   AVVideoCleanApertureHorizontalOffsetKey: 0,
                                   AVVideoCleanApertureVerticalOffsetKey: 0],
         AVVideoPixelAspectRatioKey: [AVVideoPixelAspectRatioHorizontalSpacingKey: 2,
                                      AVVideoPixelAspectRatioVerticalSpacingKey: 1],
         AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                                     AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                                     AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]]
    }
    private func makeAudioFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("unit-3-audio-fixture-\(UUID().uuidString).caf")
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 9_600) else {
            throw MediaFixtureError.setup("audio buffer")
        }
        buffer.frameLength = 9_600
        memset(buffer.floatChannelData![0], 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
    private func time(_ value: Int64) -> CMTime { CMTime(value: value, timescale: 600) }
}
