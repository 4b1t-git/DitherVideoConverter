import AVFoundation
import XCTest
@testable import AnciiVideoGenerator

final class AudioPolicyTests: XCTestCase {
    func testPolicyMatrixDisclosesAbsentPassthroughAndAACFallback() async throws {
        var urls: [URL] = []
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        let absent = try await AudioPolicy.decision(for: nil)
        XCTAssertEqual(absent.mode, .absent)
        XCTAssertEqual(absent.disclosure(at: .preflight), "No audio will be exported.")
        XCTAssertEqual(absent.disclosure(at: .completion), "Export completed without audio.")

        let aacURL = try makeAudio(formatID: kAudioFormatMPEG4AAC, rate: 48_000, channels: 2)
        urls.append(aacURL)
        let passthrough = try await AudioPolicy.decision(for: try await audioTrack(aacURL))
        XCTAssertEqual(passthrough.mode, .passthrough)
        XCTAssertTrue(passthrough.writerCompatibilityWasProven)
        XCTAssertNil(passthrough.writerOutputSettings)
        XCTAssertNotNil(passthrough.sourceFormatHint)
        XCTAssertTrue(passthrough.disclosure(at: .preflight).contains("passthrough"))
        XCTAssertTrue(passthrough.disclosure(at: .completion).contains("passthrough"))

        let pcmURL = try makeAudio(formatID: kAudioFormatLinearPCM, rate: 44_100, channels: 2)
        urls.append(pcmURL)
        let pcmTrack = try await audioTrack(pcmURL)
        let fallback = try await AudioPolicy.decision(for: pcmTrack)
        let settings = try XCTUnwrap(fallback.writerOutputSettings)
        XCTAssertEqual(fallback.mode, .aacFallback)
        XCTAssertTrue(fallback.writerCompatibilityWasProven)
        XCTAssertEqual(settings[AVFormatIDKey] as? UInt32, kAudioFormatMPEG4AAC)
        XCTAssertEqual(settings[AVSampleRateKey] as? Double, 44_100)
        XCTAssertEqual(settings[AVNumberOfChannelsKey] as? UInt32, 2)
        XCTAssertEqual(layoutTag(try XCTUnwrap(settings[AVChannelLayoutKey] as? Data)),
                       kAudioChannelLayoutTag_Stereo)
        XCTAssertFalse(fallback.promisesBitIdentity)
        XCTAssertTrue(fallback.disclosure(at: .preflight).contains("AAC fallback"))
        XCTAssertTrue(fallback.disclosure(at: .completion).contains("not bit-identical"))
    }

    func testNormalizedAudioTimingPreservesGapAndRejectsNonnumericTime() throws {
        let timeline = try TimelineNormalizer.normalize(
            video: [sample(1_000, 300)], audio: [sample(1_000, 100), sample(1_200, 100)]
        )
        XCTAssertEqual(CMTimeCompare(timeline.audio[0].presentationTime, .zero), 0)
        XCTAssertEqual(CMTimeCompare(timeline.audio[1].presentationTime, time(200)), 0)
        let gap = CMTimeSubtract(timeline.audio[1].presentationTime,
                                 CMTimeAdd(timeline.audio[0].presentationTime, timeline.audio[0].duration))
        XCTAssertEqual(CMTimeCompare(gap, time(100)), 0)
        XCTAssertThrowsError(try TimelineNormalizer.normalize(
            video: [sample(0, 100)],
            audio: [MediaSampleTiming(presentationTime: .indefinite, duration: time(100))]
        )) { XCTAssertEqual($0 as? TimelineNormalizationError, .invalidTiming) }
    }

    func testAACFallbackTriangulatesMonoRateAndLayout() async throws {
        let url = try makeAudio(formatID: kAudioFormatLinearPCM, rate: 32_000, channels: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let decision = try await AudioPolicy.decision(for: try await audioTrack(url))
        let settings = try XCTUnwrap(decision.writerOutputSettings)
        XCTAssertEqual(decision.mode, .aacFallback)
        XCTAssertEqual(settings[AVSampleRateKey] as? Double, 32_000)
        XCTAssertEqual(settings[AVNumberOfChannelsKey] as? UInt32, 1)
        XCTAssertEqual(layoutTag(try XCTUnwrap(settings[AVChannelLayoutKey] as? Data)),
                       kAudioChannelLayoutTag_Mono)
        XCTAssertTrue(decision.disclosure(at: .preflight).contains("32000 Hz, and 1 channels"))
    }

    func testAVFoundationRoundTripMatrixPreservesGapPrimingAndEndAlignment() async throws {
        var urls: [URL] = []
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let aacURL = try makeAudio(formatID: kAudioFormatMPEG4AAC, rate: 48_000, channels: 2)
        let pcmURL = try makeAudio(formatID: kAudioFormatLinearPCM, rate: 44_100, channels: 2)
        urls += [aacURL, pcmURL]

        let aacAsset = AVURLAsset(url: aacURL)
        let passthrough = try await AudioPolicy.decision(for: try await audioTrack(aacURL))
        let passthroughEvidence = try await roundTrip(aacAsset, using: passthrough)
        urls.append(passthroughEvidence.url)
        XCTAssertEqual(passthroughEvidence.subtype, kAudioFormatMPEG4AAC)
        XCTAssertLessThanOrEqual(abs(CMTimeGetSeconds(passthroughEvidence.start)), 1.0 / 48_000)

        let gappedAsset = try await gappedComposition(pcmURL)
        let gappedTracks = try await gappedAsset.loadTracks(withMediaType: .audio)
        let fallback = try await AudioPolicy.decision(for: try XCTUnwrap(gappedTracks.first))
        let fallbackEvidence = try await roundTrip(gappedAsset, using: fallback)
        urls.append(fallbackEvidence.url)
        XCTAssertEqual(fallbackEvidence.subtype, kAudioFormatMPEG4AAC)
        XCTAssertEqual(fallbackEvidence.sampleRate, 44_100, accuracy: 0.5)
        XCTAssertEqual(fallbackEvidence.channels, 2)
        XCTAssertLessThanOrEqual(abs(CMTimeGetSeconds(fallbackEvidence.start)), 1_024.0 / 44_100)
        XCTAssertGreaterThan(CMTimeGetSeconds(fallbackEvidence.end), 0.25, "The 100 ms source gap must not collapse")
        try AudioPolicy.validateEndAlignment(audioEnd: fallbackEvidence.end, videoEnd: time(300))
        XCTAssertThrowsError(try AudioPolicy.validateEndAlignment(audioEnd: time(351), videoEnd: time(300)))
        print("AUDIO_MATRIX passthroughSubtype=\(passthroughEvidence.subtype) passthroughStart=\(CMTimeGetSeconds(passthroughEvidence.start)) fallbackSubtype=\(fallbackEvidence.subtype) fallbackRate=\(fallbackEvidence.sampleRate) fallbackChannels=\(fallbackEvidence.channels) fallbackStart=\(CMTimeGetSeconds(fallbackEvidence.start)) fallbackEnd=\(CMTimeGetSeconds(fallbackEvidence.end)) retainedGap=0.1 endDrift=\(abs(CMTimeGetSeconds(CMTimeSubtract(fallbackEvidence.end, time(300)))))")
    }

    private func makeAudio(formatID: AudioFormatID, rate: Double, channels: AVAudioChannelCount) throws -> URL {
        let ext = formatID == kAudioFormatMPEG4AAC ? "m4a" : "caf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("unit-4-\(UUID()).\(ext)")
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate / 5)) else {
            throw AudioTestError.setup("audio format")
        }
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![channel][frame] = sin(Float(frame) * 0.03125)
            }
        }
        let settings: [String: Any] = formatID == kAudioFormatMPEG4AAC
            ? [AVFormatIDKey: formatID, AVSampleRateKey: rate,
               AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: 128_000]
            : format.settings
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
        return url
    }

    private func audioTrack(_ url: URL) async throws -> AVAssetTrack {
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        return try XCTUnwrap(tracks.first)
    }

    private func gappedComposition(_ url: URL) async throws -> AVMutableComposition {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let source = try XCTUnwrap(tracks.first)
        let composition = AVMutableComposition()
        let output = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio,
                                                               preferredTrackID: kCMPersistentTrackID_Invalid))
        try output.insertTimeRange(CMTimeRange(start: .zero, duration: time(100)), of: source, at: time(1_000))
        try output.insertTimeRange(CMTimeRange(start: time(100), duration: time(80)), of: source, at: time(1_200))
        return composition
    }

    private func roundTrip(_ asset: AVAsset, using policy: AudioPolicyDecision) async throws -> AudioEvidence {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        if let compositionTrack = track as? AVCompositionTrack,
           let retainedStart = compositionTrack.segments.filter({ !$0.isEmpty })
            .map(\.timeMapping.target.start).min(by: { CMTimeCompare($0, $1) < 0 }) {
            let assetDuration = try await asset.load(.duration)
            reader.timeRange = CMTimeRange(start: retainedStart,
                                           duration: CMTimeSubtract(assetDuration, retainedStart))
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: policy.readerOutputSettings)
        guard reader.canAdd(output) else { throw AudioTestError.setup("reader output") }
        reader.add(output)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("unit-4-output-\(UUID()).mov")
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: policy.writerOutputSettings,
                                       sourceFormatHint: policy.sourceFormatHint)
        guard writer.canAdd(input) else { throw AudioTestError.setup("writer input") }
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else { throw AudioTestError.pipeline(reader.error ?? writer.error) }
        writer.startSession(atSourceTime: .zero)
        var epoch: CMTime?
        let deadline = Date().addingTimeInterval(5)
        while let sample = output.copyNextSampleBuffer() {
            let origin = epoch ?? CMSampleBufferGetPresentationTimeStamp(sample)
            epoch = origin
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, Date() < deadline else { throw AudioTestError.timeout(writer.error) }
                try await Task.sleep(for: .milliseconds(1))
            }
            guard input.append(try shifted(sample, by: origin)) else { throw AudioTestError.pipeline(writer.error) }
        }
        guard reader.status == .completed else { throw AudioTestError.pipeline(reader.error) }
        input.markAsFinished()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else { throw AudioTestError.pipeline(writer.error) }
        return try await inspect(url)
    }

    private func shifted(_ sample: CMSampleBuffer, by epoch: CMTime) throws -> CMSampleBuffer {
        var needed = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &needed)
        var timing = Array(repeating: CMSampleTimingInfo(), count: needed)
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: needed, arrayToFill: &timing, entriesNeededOut: &needed)
        for index in timing.indices {
            timing[index].presentationTimeStamp = CMTimeSubtract(timing[index].presentationTimeStamp, epoch)
            if timing[index].decodeTimeStamp.isNumeric {
                timing[index].decodeTimeStamp = CMTimeSubtract(timing[index].decodeTimeStamp, epoch)
            }
        }
        var copy: CMSampleBuffer?
        let result = CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample,
            sampleTimingEntryCount: timing.count, sampleTimingArray: &timing, sampleBufferOut: &copy)
        guard result == noErr, let copy else { throw AudioTestError.setup("sample timing") }
        return copy
    }

    private func inspect(_ url: URL) async throws -> AudioEvidence {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let formats = try await track.load(.formatDescriptions)
        let format = try XCTUnwrap(formats.first)
        let description = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee)
        let range = try await track.load(.timeRange)
        return AudioEvidence(url: url, start: range.start, end: CMTimeAdd(range.start, range.duration),
                             sampleRate: description.mSampleRate, channels: description.mChannelsPerFrame,
                             subtype: CMFormatDescriptionGetMediaSubType(format))
    }

    private func layoutTag(_ data: Data) -> AudioChannelLayoutTag {
        var layout = AudioChannelLayout()
        withUnsafeMutableBytes(of: &layout) { data.copyBytes(to: $0) }
        return layout.mChannelLayoutTag
    }
    private func sample(_ pts: Int64, _ duration: Int64) -> MediaSampleTiming {
        MediaSampleTiming(presentationTime: time(pts), duration: time(duration))
    }
    private func time(_ value: Int64) -> CMTime { CMTime(value: value, timescale: 1_000) }
}

private struct AudioEvidence { let url: URL; let start, end: CMTime; let sampleRate: Double; let channels: UInt32; let subtype: FourCharCode }
private enum AudioTestError: Error { case setup(String), pipeline(Error?), timeout(Error?) }
