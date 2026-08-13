import SwiftUI

/// SwiftUI preview surface. The frame `Canvas` (R3-010) is split into `PreviewFrameView`, whose
/// `Equatable` conformance depends ONLY on the snapshot, so a per-timestamp overlay bump does NOT
/// repaint the O(W×H) canvas. The live `AVPlayer`/`AVPlayerItemVideoOutput`/`CVDisplayLink` loop
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

/// Frame canvas; wrapped in `EquatableView` by `PreviewView` so SwiftUI re-renders it ONLY when the
/// snapshot changes. A timestamp-only overlay bump leaves this view's inputs equal → skipped (R3-010).
struct PreviewFrameView: View, Equatable {
    let snapshot: PreviewSnapshot?
    var body: some View {
        Canvas { context, size in
            guard let snapshot else { return }
            let request = snapshot.request
            let cell = CGSize(width: size.width / Double(request.width), height: size.height / Double(request.height))
            for y in 0..<request.height {
                for x in 0..<request.width {
                    let value = snapshot.pixels[y * request.width + x]
                    let rect = CGRect(x: Double(x) * cell.width, y: Double(y) * cell.height,
                                      width: cell.width, height: cell.height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 0),
                                 with: .color(Color(white: Double(value) / 255, opacity: 1)))
                }
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