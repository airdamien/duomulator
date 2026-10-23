import SwiftUI

/// Settings › Transfers (and a tap on the import banner): every file being imported, what
/// happened to it, and Retry / Skip / Cancel.
struct TransfersView: View {
    @ObservedObject var queue: ImportQueue = .shared

    private var active: [ImportQueue.Item] { queue.items.filter { $0.state == .copying || $0.state == .waiting } }
    private var failed: [ImportQueue.Item] { queue.items.filter { $0.state == .failed } }
    private var finished: [ImportQueue.Item] {
        queue.items.filter { $0.state.isFinished && $0.state != .failed }.reversed()
    }

    var body: some View {
        List {
            if queue.items.isEmpty {
                ContentUnavailableView("No Transfers", systemImage: "arrow.down.doc",
                                       description: Text("Games you add with + show up here while they copy."))
            }
            if !active.isEmpty {
                Section("In Progress") {
                    ForEach(active) { item in
                        TransferRow(item: item, progress: item.state == .copying ? queue.progress : nil)
                            .swipeActions { Button("Skip", role: .destructive) { queue.skip(item.id) } }
                    }
                    Button("Cancel All", role: .destructive) { queue.cancelAll() }
                }
            }
            if !failed.isEmpty {
                Section {
                    ForEach(failed) { item in
                        TransferRow(item: item, progress: nil)
                            .swipeActions { Button("Retry") { queue.retry(item.id) }.tint(.accentColor) }
                    }
                    Button("Retry All") { queue.retryAllFailed() }
                } header: {
                    Text("Failed")
                } footer: {
                    Text("Each file is tried \(ImportQueue.maxAttempts) times before it's set aside; the rest keep importing.")
                }
            }
            if !finished.isEmpty {
                Section("Finished") {
                    ForEach(finished) { TransferRow(item: $0, progress: nil) }
                    Button("Clear Finished") { queue.clearFinished() }
                }
            }
        }
        .navigationTitle("Transfers")
    }
}

private struct TransferRow: View {
    let item: ImportQueue.Item
    let progress: ROMLibrary.ImportProgress?

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                if let progress, let total = progress.bytesTotal, total > 0 {
                    ProgressView(value: Double(min(progress.bytesDone, total)), total: Double(total))
                }
                Text(status)
                    .font(.caption)
                    .foregroundStyle(item.state == .failed ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder private var icon: some View {
        switch item.state {
        case .copying: ProgressView()
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .skipped: Image(systemName: "forward.end.circle").foregroundStyle(.secondary)
        case .duplicate: Image(systemName: "equal.circle").foregroundStyle(.secondary)
        case .unsupported: Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
    }

    private var status: String {
        let size = item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        switch item.state {
        case .copying:
            guard let progress, let total = progress.bytesTotal else { return "Waiting for the file…" }
            var text = "\(bytes(progress.bytesDone)) of \(bytes(total))"
            if progress.bytesPerSecond > 0 { text += " · \(bytes(Int64(progress.bytesPerSecond)))/s" }
            if item.attempts > 1 { text += " · try \(item.attempts) of \(ImportQueue.maxAttempts)" }
            return text
        case .waiting:
            if item.bytesDone > 0 { return "Waiting · resumes at \(bytes(item.bytesDone))" }
            return ["Waiting", size].compactMap { $0 }.joined(separator: " · ")
        case .done: return ["Added", size].compactMap { $0 }.joined(separator: " · ")
        case .failed: return item.message ?? "Failed"
        case .skipped: return "Skipped"
        case .duplicate: return "Already in your library"
        case .unsupported: return "Not a supported game file"
        }
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
