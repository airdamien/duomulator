import SwiftUI

/// Preferences read by the gameplay modules (keys in `AppSettings`) plus control help.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppSettings.hapticsKey) private var hapticsEnabled = true
    @AppStorage(AppSettings.postureOverrideKey) private var postureOverride = AppSettings.PostureOverride.auto.rawValue
    @AppStorage(AppSettings.scalingKey) private var scaling = AppSettings.Scaling.aspectFit.rawValue
    @AppStorage(AppSettings.filterKey) private var filter = AppSettings.Filter.nearest.rawValue

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
                    ControlRow(key: "Face buttons", action: "Nintendo positions")
                    ControlRow(key: "Options + Menu", action: "Menu")
                } header: {
                    Text("Game Controller")
                } footer: {
                    Text("Buttons map by position, not label: the right face button is A and the bottom is B, as on a SNES pad (and the NES pad's A and B). Touch controls hide while a controller is connected, except below the fold in DS mode. On DS games, tap the lower screen to use the touch screen.")
                }

                Section {
                    LabeledContent("Version", value: Self.versionString)
                } header: {
                    Text("About")
                } footer: {
                    Text("Duomulator uses the snes9x emulation core (SNES), used under its non-commercial license, FCEUmm (NES), under the GPL-2.0, melonDS (DS), under the GPL-3.0, and PicoDrive (Genesis, 32X, Sega CD), under its non-commercial license. DS games run with melonDS's built-in replacement BIOS, so no BIOS files are needed. Duomulator includes no games: only play ROMs dumped from cartridges you own.")
                }
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
