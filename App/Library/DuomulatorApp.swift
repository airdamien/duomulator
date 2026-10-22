import SwiftUI

/// App entry point: prepares the on-disk layout and settings defaults, then shows the library.
/// Fully offline — nothing in the app touches the network.
@main
struct DuomulatorApp: App {
    @StateObject private var library: ROMLibrary

    init() {
        GamePaths.ensureDirectories()
        AppSettings.registerDefaults()
        _library = StateObject(wrappedValue: ROMLibrary())
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .preferredColorScheme(.dark)
                .tint(.purple)
        }
    }
}
