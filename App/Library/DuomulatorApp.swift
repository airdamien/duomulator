import SwiftUI

/// App entry point: prepares the on-disk layout and settings defaults, then shows the library.
/// Offline apart from the optional box art downloads.
@main
struct DuomulatorApp: App {
    @StateObject private var library: ROMLibrary

    init() {
        GamePaths.ensureDirectories()
        AppSettings.registerDefaults()
        DemoGames.installOnFirstLaunch()
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

    @MainActor private static var didAutolaunch = false

    /// Debug/testing hook: `xcrun simctl launch <udid> io.kurast.duomulator -autolaunchROM
    /// "<file in Documents/ROMs>"` opens that game straight away. Launch arguments land in
    /// UserDefaults' argument domain, so normal launches never see the key.
    private static func autolaunchIfRequested() {
        #if DEBUG
        // `.task` re-runs whenever the library reappears (e.g. after quitting a game), so
        // only honor the argument once per launch.
        guard !didAutolaunch,
              let name = UserDefaults.standard.string(forKey: "autolaunchROM") else { return }
        didAutolaunch = true
        let rom = GamePaths.roms.appending(path: name)
        guard FileManager.default.fileExists(atPath: rom.path) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            GameLauncher.play(rom) {}
        }
        #endif
    }
}
