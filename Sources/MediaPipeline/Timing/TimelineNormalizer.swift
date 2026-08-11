import CoreMedia

struct MediaSampleTiming: Equatable {
    let presentationTime: CMTime
    let duration: CMTime
}

enum TimelineNormalizationError: Error { case missingVideo, invalidTiming }

struct NormalizedTimeline {
    let epoch: CMTime
    let video: [MediaSampleTiming]
    let audio: [MediaSampleTiming]
    let sourceDuration: CMTime

    var videoGaps: [CMTime] {
        zip(video, video.dropFirst()).map {
            CMTimeSubtract($1.presentationTime, CMTimeAdd($0.presentationTime, $0.duration))
        }
    }

    func isWithinFinalVideoSample(of referenceDuration: CMTime) -> Bool {
        guard let tolerance = video.last?.duration else { return false }
        return abs(CMTimeGetSeconds(CMTimeSubtract(sourceDuration, referenceDuration)))
            <= CMTimeGetSeconds(tolerance)
    }
}

enum TimelineNormalizer {
    static func normalize(video: [MediaSampleTiming], audio: [MediaSampleTiming]) throws -> NormalizedTimeline {
        guard !video.isEmpty else { throw TimelineNormalizationError.missingVideo }
        let samples = video + audio
		guard samples.allSatisfy({ $0.presentationTime.isNumeric && $0.duration.isNumeric
			&& CMTimeCompare($0.duration, .zero) > 0 }) else {
            throw TimelineNormalizationError.invalidTiming
        }
        let epoch = samples.map(\.presentationTime).min { CMTimeCompare($0, $1) < 0 }!
        let shift: (MediaSampleTiming) -> MediaSampleTiming = {
            MediaSampleTiming(presentationTime: CMTimeSubtract($0.presentationTime, epoch),
                              duration: $0.duration)
        }
        let normalizedVideo = video.map(shift)
        let duration = normalizedVideo.map { CMTimeAdd($0.presentationTime, $0.duration) }
            .max { CMTimeCompare($0, $1) < 0 }!
        return NormalizedTimeline(epoch: epoch, video: normalizedVideo,
                                  audio: audio.map(shift), sourceDuration: duration)
    }
}
