import AppKit
import UniformTypeIdentifiers

/// The ONE deliberately untested seam in the import/export path.
///
/// `NSOpenPanel` and `NSSavePanel` are modal AppKit UI: `runModal()` spins its own run loop and
/// waits for a human, so there is nothing an XCTest process can drive without a UI-automation layer
/// this project does not have. Rather than pretend otherwise with a test that only proves a panel
/// object can be allocated, this type is kept to panel construction and presentation ONLY — no
/// validation, no `AVAsset` construction, no coordinator calls. Every decision downstream of it
/// takes a plain `URL` (`LifecycleCoordinator.openAsset(url:)` / `exportToFile(url:)`) and IS unit
/// tested, so the untested surface is exactly "which URL did the human point at".
@MainActor
enum FileDialogs {
    /// Presents the open panel and returns the chosen movie, or `nil` when the user cancels.
    /// A cancel is an ordinary outcome, not a failure: the caller must leave state untouched.
    static func chooseMovie() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        // `.movie` alone already covers both concrete types, but naming them keeps the container
        // formats the pipeline actually validates (QuickTime / MPEG-4) visible at this seam.
        panel.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie]
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Presents the save panel for the export destination, or `nil` when the user cancels.
    /// `ExportSession` writes a QuickTime movie, so the panel offers exactly that type.
    static func chooseExportDestination(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
