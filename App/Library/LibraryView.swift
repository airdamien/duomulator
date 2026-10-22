import SwiftUI
import UniformTypeIdentifiers

/// Home screen: one folder per manufacturer (Nintendo, Sega), each holding its consoles, each
/// holding that console's games with import, delete, rename and launch.
struct LibraryView: View {
    @EnvironmentObject private var library: ROMLibrary
    @Environment(\.scenePhase) private var scenePhase

    @State private var showingImporter = false
    @State private var showingSettings = false
    @State private var pendingDelete: ROMEntry?
    @State private var renaming: ROMEntry?
    @State private var renameText = ""
    @State private var alertMessage: AlertMessage?

    struct AlertMessage: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    /// Generic data plus archives; anything that isn't a ROM extension is filtered out after
    /// picking, which is more robust than declaring custom UTTypes for every dump format.
    private static let importTypes: [UTType] = {
        var types: [UTType] = [.data, .archive, .zip]
        for ext in GamePaths.romExtensions.sorted() {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }()

    var body: some View {
        NavigationStack {
            Group {
                if library.entries.isEmpty {
                    emptyState
                } else {
                    folderList
                }
            }
            .navigationTitle("Duomulator")
            .navigationDestination(for: Route.self) { route in destination(route) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingSettings = true } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingImporter = true } label: {
                        Label("Add ROMs", systemImage: "plus")
                    }
                }
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: Self.importTypes,
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): report(library.importFiles(urls))
            case .failure(let error):
                alertMessage = AlertMessage(title: "Import Failed", message: error.localizedDescription)
            }
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .onOpenURL { url in report(library.handleOpenURL(url)) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { library.refresh() }
        }
        .confirmationDialog(deleteTitle, isPresented: deleteDialogBinding, titleVisibility: .visible,
                            presenting: pendingDelete) { entry in
            Button("Delete ROM Only", role: .destructive) { delete(entry, includingSaves: false) }
            if !ROMLibrary.saveFiles(for: entry.url).isEmpty {
                Button("Delete ROM and Saves", role: .destructive) { delete(entry, includingSaves: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text(ROMLibrary.saveFiles(for: entry.url).isEmpty
                 ? "This removes \(entry.fileName) from this iPhone."
                 : "Battery saves and save states can be kept in case you add the game again.")
        }
        .alert("Rename", isPresented: renameAlertBinding, presenting: renaming) { entry in
            TextField("Name", text: $renameText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Rename") { rename(entry) }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text("Saves are renamed with the ROM. The .\(entry.url.pathExtension) extension is kept.")
        }
        .alert(item: $alertMessage) { message in
            Alert(title: Text(message.title), message: Text(message.message))
        }
    }

    // MARK: Subviews

    /// A screen in the library hierarchy. Routes carry identifiers, not snapshots, so open
    /// screens follow the library as files are added or removed.
    enum Route: Hashable {
        case maker(String)
        case system(GameSystem)
        /// ROMs whose console can't be told.
        case other
    }

    /// Top level: one row per manufacturer.
    private var folderList: some View {
        List {
            Section {
                ForEach(library.makers, id: \.name) { maker in
                    NavigationLink(value: Route.maker(maker.name)) {
                        FolderRow(title: maker.name, entries: maker.systems.flatMap(\.entries),
                                  detail: maker.systems.map(\.system.displayName).joined(separator: ", "))
                    }
                }
                if !library.unknownEntries.isEmpty {
                    NavigationLink(value: Route.other) {
                        FolderRow(title: "Other", entries: library.unknownEntries)
                    }
                }
            } footer: {
                Text("\(library.entries.count) game\(library.entries.count == 1 ? "" : "s") · Add more with +, the Files app, or Finder over USB.")
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { library.refresh() }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .maker(let name):
            makerList(name)
        case .system(let system):
            gameList(library.makers.flatMap(\.systems).first { $0.system == system }?.entries ?? [],
                     title: system.displayName)
        case .other:
            gameList(library.unknownEntries, title: "Other")
        }
    }

    /// A manufacturer's consoles, in release order.
    private func makerList(_ name: String) -> some View {
        let systems = library.makers.first { $0.name == name }?.systems ?? []
        return List {
            ForEach(systems, id: \.system) { folder in
                NavigationLink(value: Route.system(folder.system)) {
                    FolderRow(title: folder.system.displayName, entries: folder.entries)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { library.refresh() }
        .overlay {
            if systems.isEmpty {
                ContentUnavailableView("No \(name) Games", systemImage: "folder",
                                       description: Text("Add ROMs with +."))
            }
        }
        .navigationTitle(name)
    }

    /// One folder's games, alphabetical.
    private func gameList(_ entries: [ROMEntry], title folder: String) -> some View {
        List {
            ForEach(entries) { entry in
                Button { play(entry) } label: { ROMRow(entry: entry) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { pendingDelete = entry } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button { beginRename(entry) } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        .tint(.indigo)
                    }
                    .contextMenu {
                        Button { play(entry) } label: {
                            Label(entry.hasSuspendState ? "Resume" : "Play", systemImage: "play.fill")
                        }
                        Button { beginRename(entry) } label: { Label("Rename", systemImage: "pencil") }
                        Button(role: .destructive) { pendingDelete = entry } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { library.refresh() }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("No \(folder) Games", systemImage: "folder",
                                       description: Text("Add ROMs with +."))
            }
        }
        .navigationTitle(folder)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Games Yet", systemImage: "gamecontroller")
        } description: {
            Text("Add ROMs with +, from the Files app (On My iPhone ▸ Duomulator ▸ ROMs), or via Finder over USB.\n\nSNES: .sfc .smc .swc .fig .bs .st\nNES: .nes .unf\nDS: .nds\nGenesis: .md .gen .smd .bin · 32X: .32x\nSega CD: .chd, or .cue with its .bin tracks (needs your console's BIOS in the System folder)\nZipped cartridge ROMs (.zip) work too.")
        } actions: {
            Button { showingImporter = true } label: {
                Label("Add ROMs", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: Actions

    private func play(_ entry: ROMEntry) {
        guard FileManager.default.fileExists(atPath: entry.url.path) else {
            library.refresh()
            alertMessage = AlertMessage(title: "ROM Missing",
                                        message: "\(entry.fileName) is no longer in the ROMs folder.")
            return
        }
        GameLauncher.play(entry.url) { [library] in library.refresh() }
    }

    private func beginRename(_ entry: ROMEntry) {
        renameText = entry.url.deletingPathExtension().lastPathComponent
        renaming = entry
    }

    private func rename(_ entry: ROMEntry) {
        do {
            try library.rename(entry, to: renameText)
        } catch {
            alertMessage = AlertMessage(title: "Couldn't Rename", message: error.localizedDescription)
        }
    }

    private func delete(_ entry: ROMEntry, includingSaves: Bool) {
        do {
            try library.delete(entry, includingSaves: includingSaves)
        } catch {
            alertMessage = AlertMessage(title: "Couldn't Delete", message: error.localizedDescription)
        }
    }

    private func report(_ result: ROMLibrary.ImportReport) {
        guard let problems = result.problemSummary else { return }
        let title = result.imported.isEmpty
            ? "Nothing Imported"
            : "Imported \(result.imported.count) of \(result.imported.count + result.duplicates.count + result.unsupported.count + result.failed.count)"
        alertMessage = AlertMessage(title: title, message: problems)
    }

    // MARK: Bindings

    private var deleteTitle: String {
        pendingDelete.map { "Delete \"\($0.title)\"?" } ?? "Delete?"
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }
}

// MARK: - Row

private struct ROMRow: View {
    let entry: ROMEntry

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "gamecontroller.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(entry.fileExtension)
                    Text("·")
                    Text(Self.sizeFormatter.string(fromByteCount: entry.fileSize))
                    if entry.hasSRAM {
                        Image(systemName: "memorychip")
                            .accessibilityLabel("Has battery save")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if entry.hasSuspendState {
                Text("Resume")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.tint, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(entry.hasSuspendState ? "Resumes where you left off" : "Starts the game")
    }
}

/// A folder row: name, game count, how many have a resume point, and an optional detail
/// (a manufacturer's consoles).
private struct FolderRow: View {
    let title: String
    let entries: [ROMEntry]
    var detail: String? = nil

    var body: some View {
        let resumable = entries.filter(\.hasSuspendState).count
        HStack(spacing: 14) {
            Image(systemName: "folder.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text([detail, "\(entries.count) game\(entries.count == 1 ? "" : "s")",
                      resumable > 0 ? "\(resumable) to resume" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
