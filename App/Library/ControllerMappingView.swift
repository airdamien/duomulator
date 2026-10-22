import SwiftUI

/// Settings > Controller Mapping: the systems, grouped by manufacturer.
struct ControllerMappingList: View {
    var body: some View {
        let makers = Dictionary(grouping: GameSystem.allCases, by: \.manufacturer)
            .sorted { $0.key < $1.key }
        List {
            ForEach(makers, id: \.key) { maker, systems in
                Section(maker) {
                    ForEach(systems.sorted { $0.releaseYear < $1.releaseYear }, id: \.self) { system in
                        NavigationLink(system.displayName) { ControllerMappingEditor(system: system) }
                    }
                }
            }
        }
        .navigationTitle("Controller Mapping")
    }
}

/// One system's mapping: every physical button and the emulated button it presses.
struct ControllerMappingEditor: View {
    let system: GameSystem
    @State private var mapping: ControllerMapping

    init(system: GameSystem) {
        self.system = system
        _mapping = State(initialValue: ControllerMapping.load(for: system))
    }

    var body: some View {
        let defaults = ControllerMapping.defaults(for: system)
        let targets = [SNESButtons()] + ControllerMapping.targets(for: system)
        List {
            Section {
                ForEach(PhysicalButton.allCases, id: \.self) { button in
                    Picker(selection: binding(for: button)) {
                        ForEach(targets, id: \.rawValue) { target in
                            Text(ButtonLabels.label(target, pad: system.padStyle, system: system))
                                .tag(target)
                        }
                    } label: {
                        HStack {
                            Text(button.displayName)
                            if mapping.bindings[button] != defaults.bindings[button] {
                                Image(systemName: "pencil.circle.fill")
                                    .foregroundStyle(.tint)
                                    .accessibilityLabel("Changed")
                            }
                        }
                    }
                }
            } footer: {
                Text("The d-pad and left stick always steer. Menu and View pressed together open the in-game menu. Applies to \(system.displayName) games from the next one you start.")
            }

            Section {
                Button("Reset to Defaults", role: .destructive) {
                    ControllerMapping.reset(for: system)
                    mapping = ControllerMapping.load(for: system)
                }
                .disabled(mapping == defaults)
            }
        }
        .navigationTitle(system.displayName)
    }

    private func binding(for button: PhysicalButton) -> Binding<SNESButtons> {
        Binding {
            mapping.bindings[button] ?? []
        } set: { target in
            mapping.bindings[button] = target
            mapping.save()
        }
    }
}
