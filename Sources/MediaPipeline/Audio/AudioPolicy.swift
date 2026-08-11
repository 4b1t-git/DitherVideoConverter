import AVFoundation

enum AudioPolicyMode: Equatable { case absent, passthrough, aacFallback }
enum AudioDisclosureStage { case preflight, completion }

enum AudioPolicyError: LocalizedError {
    case missingFormatDescription
    case unsupportedFallback(sampleRate: Double, channels: UInt32)
    case invalidEndTime
    case endDrift(seconds: Double)

    var errorDescription: String? {
        switch self {
        case .missingFormatDescription:
            return "Audio format description is unavailable; choose a readable local source."
        case let .unsupportedFallback(rate, channels):
            return "AAC fallback does not support the source audio at \(rate) Hz with \(channels) channels."
        case .invalidEndTime:
            return "Audio/video end times must be finite numeric timestamps."
        case let .endDrift(seconds):
            return "Audio/video end drift is \(seconds) seconds; the maximum is 0.05 seconds."
        }
    }
}

struct AudioPolicyDecision {
    let mode: AudioPolicyMode
    let readerOutputSettings: [String: Any]?
    let writerOutputSettings: [String: Any]?
    let sourceFormatHint: CMAudioFormatDescription?
    let writerCompatibilityWasProven: Bool
    let promisesBitIdentity: Bool
    let sampleRate: Double?
    let channels: UInt32?

    func disclosure(at stage: AudioDisclosureStage) -> String {
        switch (mode, stage) {
        case (.absent, .preflight): return "No audio will be exported."
        case (.absent, .completion): return "Export completed without audio."
        case (.passthrough, .preflight): return "Compatible source audio will use verified .mov passthrough."
        case (.passthrough, .completion): return "Export completed with verified audio passthrough."
        case (.aacFallback, .preflight):
            return "AAC fallback will preserve timing, \(Int(sampleRate ?? 0)) Hz, and \(channels ?? 0) channels when supported; output is not bit-identical."
        case (.aacFallback, .completion):
            return "Export completed with disclosed AAC fallback; output is not bit-identical."
        }
    }
}

enum AudioPolicy {
    private static let aacBitRate = 128_000
    private static let maximumEndDrift = 0.05

    static func decision(for track: AVAssetTrack?, fileType: AVFileType = .mov) async throws -> AudioPolicyDecision {
        guard let track else {
            return AudioPolicyDecision(mode: .absent, readerOutputSettings: nil,
                writerOutputSettings: nil, sourceFormatHint: nil,
                writerCompatibilityWasProven: false, promisesBitIdentity: false,
                sampleRate: nil, channels: nil)
        }
        guard let format = try await track.load(.formatDescriptions).first,
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
            throw AudioPolicyError.missingFormatDescription
        }
        let subtype = CMFormatDescriptionGetMediaSubType(format)
        if subtype != kAudioFormatLinearPCM,
           try writerAccepts(fileType: fileType, settings: nil, sourceHint: format) {
            return AudioPolicyDecision(mode: .passthrough, readerOutputSettings: nil,
                writerOutputSettings: nil, sourceFormatHint: format,
                writerCompatibilityWasProven: true, promisesBitIdentity: false,
                sampleRate: stream.mSampleRate, channels: stream.mChannelsPerFrame)
        }
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: stream.mSampleRate,
            AVNumberOfChannelsKey: stream.mChannelsPerFrame,
            AVEncoderBitRateKey: aacBitRate
        ]
        if let layout = channelLayoutData(format, channels: stream.mChannelsPerFrame) {
            settings[AVChannelLayoutKey] = layout
        }
        guard try writerAccepts(fileType: fileType, settings: settings, sourceHint: nil) else {
            throw AudioPolicyError.unsupportedFallback(sampleRate: stream.mSampleRate,
                                                       channels: stream.mChannelsPerFrame)
        }
        return AudioPolicyDecision(mode: .aacFallback,
            readerOutputSettings: [AVFormatIDKey: kAudioFormatLinearPCM],
            writerOutputSettings: settings, sourceFormatHint: nil,
            writerCompatibilityWasProven: true, promisesBitIdentity: false,
            sampleRate: stream.mSampleRate, channels: stream.mChannelsPerFrame)
    }

    static func validateEndAlignment(audioEnd: CMTime, videoEnd: CMTime) throws {
        guard audioEnd.isNumeric, videoEnd.isNumeric else { throw AudioPolicyError.invalidEndTime }
        let drift = abs(CMTimeGetSeconds(CMTimeSubtract(audioEnd, videoEnd)))
        guard drift <= maximumEndDrift else { throw AudioPolicyError.endDrift(seconds: drift) }
    }

    private static func writerAccepts(fileType: AVFileType, settings: [String: Any]?,
                                      sourceHint: CMAudioFormatDescription?) throws -> Bool {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audio-policy-\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(url: url, fileType: fileType)
        if let settings, !writer.canApply(outputSettings: settings, forMediaType: .audio) { return false }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: sourceHint)
        return writer.canAdd(input)
    }

    private static func channelLayoutData(_ format: CMAudioFormatDescription, channels: UInt32) -> Data? {
        var size = 0
        if let layout = CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: &size), size > 0 {
            return Data(bytes: layout, count: size)
        }
        guard channels == 1 || channels == 2 else { return nil }
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1
            ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        layout.mChannelBitmap = []
        layout.mNumberChannelDescriptions = 0
        return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
    }
}
