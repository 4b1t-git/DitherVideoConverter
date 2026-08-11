import SwiftUI

/// SwiftUI-style preview surface. Renders a `PreviewSnapshot` as grayscale cells via `Canvas`
/// and overlays the source timestamp from `PreviewState` (Navigation scenario). The live
/// `AVPlayer`/`AVPlayerItemVideoOutput`/`CVDisplayLink` loop is deferred to Unit 8; this view is
/// a deterministic declarative surface driven by `PreviewState` + `PreviewSnapshot`.
struct PreviewView: View {
    @ObservedObject var state: PreviewState
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
                    context.fill(Path(roundedRect: rect, cornerRadius: 0), with: .color(Color(white: Double(value) / 255, opacity: 1)))
                }
            }
        }
        .overlay(alignment: .topLeading) { label.padding(4) }
        .frame(minWidth: 320, minHeight: 180)
    }

    @ViewBuilder private var label: some View {
        switch state.phase {
        case .playing: Text(String(format: "%.2f s", state.currentTimestamp)).font(.caption)
        case .ready: Text("Ready").font(.caption)
        case let .unsupported(reason): Text(reason).font(.caption).foregroundStyle(.red)
        case .importing: Text("Importing…").font(.caption)
        case .empty: Text("No source").font(.caption)
        }
    }
}