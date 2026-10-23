import SwiftUI

/// Preferences read by the gameplay modules (keys in `AppSettings`) plus control help.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppSettings.hapticsKey) private var hapticsEnabled = true
    @AppStorage(AppSettings.postureOverrideKey) private var postureOverride = AppSettings.PostureOverride.auto.rawValue
    @AppStorage(AppSettings.scalingKey) private var scaling = AppSettings.Scaling.aspectFit.rawValue
    @AppStorage(AppSettings.filterKey) private var filter = AppSettings.Filter.nearest.rawValue
    @AppStorage(ArtworkSettings.downloadsEnabledKey) private var artDownloads = false
    @AppStorage(ArtworkSettings.sourceURLKey) private var artSource = ArtworkSettings.defaultSourceURL
    @AppStorage(ArtworkSettings.wifiOnlyKey) private var artWiFiOnly = true
    @State private var confirmClearArt = false
    @State private var demoMessage: String?
    @EnvironmentObject private var library: ROMLibrary

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Layout", selection: $postureOverride) {
                        ForEach(AppSettings.PostureOverride.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                } header: {
                    Text("Screen")
                } footer: {
                    Text("Auto follows the hinge: half-folded puts the game above the fold and controls below, like a DS. Fully open or closed uses an overlay layout.")
                }

                Section {
                    Picker("Scaling", selection: $scaling) {
                        ForEach(AppSettings.Scaling.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Picker("Filter", selection: $filter) {
                        ForEach(AppSettings.Filter.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Video")
                } footer: {
                    Text("Integer scaling keeps every pixel the same size; Aspect Fit fills more of the screen.")
                }

                Section("Touch Controls") {
                    Toggle("Haptics", isOn: $hapticsEnabled)
                }

                if ArtworkSettings.boxArtAvailable {
                Section {
                    Toggle("Download Box Art", isOn: $artDownloads)
                    if artDownloads {
                        TextField("Source", text: $artSource)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .font(.footnote.monospaced())
                        Toggle("Wi-Fi Only", isOn: $artWiFiOnly)
                    }
                    Button("Clear Downloaded Artwork", role: .destructive) { confirmClearArt = true }
                } header: {
                    Text("Artwork")
                } footer: {
                    Text(artDownloads
                         ? "Box art is fetched from the source above (libretro-thumbnails, a community collection) only for games in your library, and kept on this iPhone. The images belong to their respective owners; Duomulator doesn't host or include any."
                         : "Games show a title screen captured on this iPhone from your own ROMs, and where you left off. Turn on Download Box Art to fetch covers from a community source.")
                }
                }

                Section {
                    ControlRow(key: "Arrow keys", action: "D-Pad")
                    ControlRow(key: "Z", action: "B")
                    ControlRow(key: "X", action: "A")
                    ControlRow(key: "A", action: "Y")
                    ControlRow(key: "S", action: "X")
                    ControlRow(key: "Q", action: "L")
                    ControlRow(key: "W", action: "R")
                    ControlRow(key: "Return", action: "Start")
                    ControlRow(key: "Right Shift", action: "Select")
                    ControlRow(key: "Esc", action: "Menu")
                } header: {
                    Text("Keyboard")
                }

                Section {
                    NavigationLink("Controller Mapping") { ControllerMappingList() }
                    ControlRow(key: "Face buttons", action: "Nintendo positions")
                    ControlRow(key: "Options + Menu", action: "Menu")
                } header: {
                    Text("Game Controller")
                } footer: {
                    Text("By default buttons map by position, not label: the right face button is A and the bottom is B, as on a SNES pad. Change it per system in Controller Mapping. With a controller connected, on-screen controls hide until you touch the screen; below the fold they always show. On DS games, tap the lower screen to use the touch screen.")
                }

                Section {
                    Button("Add Demo Games") {
                        demoMessage = DemoGames.install() == 0 ? "The demo games are already in your library." : "Added to your library."
                        library.refresh()
                    }
                } header: {
                    Text("Demo Games")
                } footer: {
                    Text(demoMessage ?? "Three small public-domain games made for Duomulator (SNES, Genesis and DS), to try the controls before adding your own.")
                }

                Section {
                    LabeledContent("Version", value: Self.versionString)
                    NavigationLink("Acknowledgements") { AcknowledgementsView() }
                    Link("Privacy Policy", destination: Self.privacyPolicyURL)
                } header: {
                    Text("About")
                } footer: {
                    Text("Duomulator runs on open-source emulation cores: snes9x, FCEUmm, melonDS, PicoDrive, FinalBurn Neo, PCSX ReARMed and Mupen64Plus-Next with GLideN64; see Acknowledgements for their licenses. It includes no games or BIOS files: only play games and BIOS files dumped from hardware you own.")
                }
            }
            .confirmationDialog("Delete all downloaded box art?", isPresented: $confirmClearArt,
                                titleVisibility: .visible) {
                Button("Delete Box Art", role: .destructive) { ArtworkStore.shared.removeAll(.boxart) }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    static let privacyPolicyURL = URL(string: "https://airdamien.github.io/duomulator/privacy.html")!

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

private struct ControlRow: View {
    let key: String
    let action: String

    var body: some View {
        LabeledContent {
            Text(action)
        } label: {
            Text(key).font(.body.monospaced())
        }
    }
}
