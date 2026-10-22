import SwiftUI
import UniformTypeIdentifiers

/// Library > BIOS Files: what each system can use, what's installed, and importing or
/// replacing a file the same way ROMs are added.
struct BIOSView: View {
    /// What the file picker is filling: one slot, or any files recognised by checksum.
    private enum ImportTarget: Equatable {
        case slot(BIOSSlot)
        case recognise
    }

    @State private var importTarget: ImportTarget?
    @State private var message: (title: String, text: String)?
    /// Bumped after every change so rows re-read the files on disk.
    @State private var revision = 0

    var body: some View {
        List {
            Section {
                Button {
                    importTarget = .recognise
                } label: {
                    Label("Import BIOS Files…", systemImage: "square.and.arrow.down")
                }
            } footer: {
                Text("Pick any number of BIOS files dumped from your own consoles; known ones are filed automatically under the names the emulators expect. Or tap a slot below to choose the file for it.")
            }

            ForEach(BIOSCatalog.groups) { group in
                Section {
                    ForEach(group.slots) { slot in
                        Button { importTarget = .slot(slot) } label: { SlotRow(slot: slot) }
                            .swipeActions(edge: .trailing) {
                                if slot.isInstalled {
                                    Button("Remove", role: .destructive) { remove(slot) }
                                }
                            }
                            .contextMenu {
                                Button { importTarget = .slot(slot) } label: {
                                    Label(slot.isInstalled ? "Replace…" : "Choose File…", systemImage: "doc")
                                }
                                if slot.isInstalled {
                                    Button(role: .destructive) { remove(slot) } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                            }
                    }
                } header: {
                    HStack {
                        Text(group.system.displayName)
                        Spacer()
                        if group.required {
                            Text(group.isSatisfied ? "Ready" : "Required")
                                .foregroundStyle(group.isSatisfied ? .green : .orange)
                        } else {
                            Text("Optional")
                        }
                    }
                } footer: {
                    Text(group.note)
                }
            }
        }
        .id(revision)
        .navigationTitle("BIOS Files")
        .fileImporter(isPresented: Binding(get: { importTarget != nil }, set: { if !$0 { importTarget = nil } }),
                      allowedContentTypes: [.data, .zip, .item],
                      allowsMultipleSelection: importTarget == .recognise) { result in
            let target = importTarget
            importTarget = nil
            guard case .success(let urls) = result, let target else {
                if case .failure(let error) = result { message = ("Import Failed", error.localizedDescription) }
                return
            }
            switch target {
            case .slot(let slot):
                guard let file = urls.first else { return }
                do {
                    try BIOSCatalog.install(file, into: slot)
                } catch {
                    message = ("Import Failed", error.localizedDescription)
                }
            case .recognise:
                let report = BIOSCatalog.importFiles(urls)
                var lines = report.installed.map { "\($0.file) → \($0.slot.system.displayName) \($0.slot.title)" }
                if !report.failed.isEmpty {
                    lines.append("Not recognised (import from a slot instead): " + report.failed.joined(separator: ", "))
                }
                message = (report.installed.isEmpty ? "Nothing Imported" : "BIOS Files Imported",
                           lines.joined(separator: "\n"))
            }
            revision += 1
        }
        .alert(message?.title ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message?.text ?? "")
        }
    }

    private func remove(_ slot: BIOSSlot) {
        do {
            try BIOSCatalog.remove(slot)
        } catch {
            message = ("Couldn't Remove", error.localizedDescription)
        }
        revision += 1
    }
}

private struct SlotRow: View {
    let slot: BIOSSlot

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: slot.isInstalled ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title3)
                .foregroundStyle(slot.isInstalled ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(slot.title).foregroundStyle(Color(uiColor: .label))
                Text(slot.fileName)
                    .font(.caption.monospaced())
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
            }
            Spacer()
            Text(slot.isInstalled ? "Replace" : "Choose")
                .font(.subheadline)
                .foregroundStyle(.tint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(slot.isInstalled ? "Installed" : "Not installed")
    }
}
