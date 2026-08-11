import Foundation

/// SwiftUI preview state-machine phase. `.unsupported` carries the actionable reason from
/// `AssetValidator`, satisfying the "processing MUST remain disabled with an actionable reason"
/// scenario. The full live-AVPlayer/CVDisplayLink loop is deferred to Unit 8.
enum PreviewPhase: Sendable, Equatable {
    case empty, importing, ready, playing, unsupported(String)
}

/// `@MainActor` UI state machine for the preview feature; the design's `WorkspaceModel` is
/// `@MainActor` and preview/export actors exchange snapshots with it. The state machine tracks
/// the current source timestamp shown by the preview (Navigation scenario).
@MainActor
final class PreviewState: ObservableObject {
    @Published private(set) var phase: PreviewPhase = .empty
    @Published private(set) var currentTimestamp: Double = 0

    func setImporting() { phase = .importing }
    func setReady(timestamp: Double) { phase = .ready; currentTimestamp = timestamp }
    func play(at timestamp: Double) { phase = .playing; currentTimestamp = timestamp }
    func scrub(to timestamp: Double) { currentTimestamp = timestamp }
    func setUnsupported(_ reason: String) { phase = .unsupported(reason) }
}