import SwiftUI

@main
struct AnciiVideoGeneratorApp: App {
    @StateObject private var previewState = PreviewState()
    var body: some Scene {
        WindowGroup {
            PreviewView(state: previewState, snapshot: nil)
        }
    }
}
