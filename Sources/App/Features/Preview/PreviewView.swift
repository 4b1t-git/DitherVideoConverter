import SwiftUI

/// SwiftUI preview surface. The frame image (R3-010) is split into `PreviewFrameView`, whose
/// `Equatable` conformance depends ONLY on the snapshot, so a per-timestamp overlay bump does NOT
/// repaint the frame. The live `AVPlayer`/`AVPlayerItemVideoOutput`/`CVDisplayLink` loop
/// is deferred to a follow-up live-preview slice; this is the deterministic declarative surface
/// driven by `PreviewState` + `PreviewSnapshot`.
struct PreviewView: View {
    @ObservedObject var state: PreviewState
    let snapshot: PreviewSnapshot?

    var body: some View {
        ZStack(alignment: .topLeading) {
            EquatableView(content: PreviewFrameView(snapshot: snapshot))
                .frame(minWidth: 320, minHeight: 180)
            PreviewOverlayView(state: state).padding(4)
        }
    }
}

/// Frame image; wrapped in `EquatableView` by `PreviewView` so SwiftUI re-renders it ONLY when the
/// snapshot changes. A timestamp-only overlay bump leaves this view's inputs equal → skipped (R3-010).
///
/// The snapshot is drawn as ONE grayscale `CGImage` rather than one filled rect per pixel: the
/// previous `Canvas` path issued O(W×H) draw calls per repaint, which only survived because the
/// test fixture is 16×8. Interpolation is explicitly OFF — this is a dither/ASCII renderer, so
/// smoothing the upscale would blend neighbouring cells and misrepresent the very output the user
/// is inspecting. A `nil` snapshot, or a snapshot too short for its own request, renders the empty
/// placeholder instead of crashing.
struct PreviewFrameView: View, Equatable {
    let snapshot: PreviewSnapshot?
    var body: some View {
        ZStack {
            Color.clear
            if let image = snapshot?.makeGrayscaleImage() {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            }
        }
        .accessibilityHidden(true)
    }
    static func == (lhs: PreviewFrameView, rhs: PreviewFrameView) -> Bool { lhs.snapshot == rhs.snapshot }
}

/// Timestamp / phase overlay. Depends on `PreviewState` only — re-evaluates on every timestamp
/// bump without recomputing the frame canvas above (R3-010).
struct PreviewOverlayView: View {
    @ObservedObject var state: PreviewState
    var body: some View {
        switch state.phase {
        case .playing: Text(String(format: "%.2f s", state.currentTimestamp)).font(.caption)
        case .ready: Text("Ready").font(.caption)
        case let .unsupported(reason): Text(reason).font(.caption).foregroundStyle(.red)
        case .importing: Text("Importing…").font(.caption)
        case .empty: Text("No source").font(.caption)
        }
    }
}