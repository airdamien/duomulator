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
                .task { Self.autolaunchIfRequested() }
        }
    }

    /// Debug/testing hook: `xcrun simctl launch <udid> io.kurast.duomulator -autolaunchROM
    /// "<file in Documents/ROMs>"` opens that game straight away. Launch arguments land in
    /// UserDefaults' argument domain, so normal launches never see the key.
    private static func autolaunchIfRequested() {
        guard let name = UserDefaults.standard.string(forKey: "autolaunchROM") else { return }
        let rom = GamePaths.roms.appending(path: name)
        guard FileManager.default.fileExists(atPath: rom.path) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            GameLauncher.play(rom) {}
        }
    }
}
