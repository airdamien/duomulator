import Foundation
import os
import UIKit

/// Copies picked and shared files into the ROMs folder one at a time, in the background,
/// and survives interruptions: the queue is saved (with a bookmark to each source file), a
/// partly copied file resumes where it stopped, a failing file is retried and then skipped
/// so the rest still import, and leftover work picks up again on the next launch.
@MainActor
final class ImportQueue: ObservableObject {
    struct Item: Codable, Identifiable, Equatable {
        enum State: String, Codable {
            case waiting, copying, done, failed, skipped, duplicate, unsupported

            var isFinished: Bool { self != .waiting && self != .copying }
        }

        let id: UUID
        let name: String
        /// Security-scoped bookmark to the source (picked files), or nil for a plain path.
        var bookmark: Data?
        var path: String?
        var size: Int64?
        var state: State = .waiting
        var bytesDone: Int64 = 0
        var attempts = 0
        /// Why it failed, for the Transfers screen.
        var message: String?
        /// File name it was saved as in the ROMs folder.
        var savedName: String?
        var added = Date()
    }

    static let shared = ImportQueue()

    @Published private(set) var items: [Item] = []
    /// What the banner shows while something is copying.
    @Published private(set) var progress: ROMLibrary.ImportProgress?
    /// Called on the main actor after each file finishes (the library rescans).
    var onItemFinished: (() -> Void)?

    static let maxAttempts = 3
    /// Seconds to wait before retry n is n × this (tests shorten it).
    var retryDelay: Double = 2

    private let storeURL: URL
    private var worker: Task<Void, Never>?
    private let stop = StopFlags()
    private var waiters: [(ids: Set<UUID>, continuation: CheckedContinuation<ROMLibrary.ImportReport, Never>)] = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var batchStart = Date()
    /// The files in the current run, in order, for "Importing 2 of 5".
    private var batchIDs: [UUID] = []
    private var batchBytesBefore: Int64 = 0
    private let log = Logger(subsystem: "io.kurast.duomulator", category: "import")

    init(storeURL: URL = ImportQueue.defaultStoreURL) {
        self.storeURL = storeURL
        if let data = try? Data(contentsOf: storeURL),
           let saved = try? JSONDecoder().decode([Item].self, from: data) {
            // Anything mid-copy when the app last stopped goes back in line (it resumes).
            items = saved.map { item in
                var item = item
                if item.state == .copying { item.state = .waiting }
                return item
            }
        }
    }

    nonisolated static var defaultStoreURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "ImportQueue.json")
    }

    // MARK: Queue

    /// Adds files and waits until all of them are done, skipped or failed.
    func importFiles(_ urls: [URL]) async -> ROMLibrary.ImportReport {
        let added = urls.map(makeItem)
        items.append(contentsOf: added)
        save()
        let ids = Set(added.map(\.id))
        if worker != nil { batchIDs.append(contentsOf: added.map(\.id)) }
        return await withCheckedContinuation { continuation in
            waiters.append((ids, continuation))
            start()
        }
    }

    /// Starts (or resumes) copying whatever is waiting. Safe to call any time.
    func start() {
        guard worker == nil, items.contains(where: { $0.state == .waiting }) else {
            settleWaiters()
            return
        }
        batchStart = Date()
        batchBytesBefore = 0
        batchIDs = items.filter { $0.state == .waiting }.map(\.id)
        beginBackgroundTime()
        worker = Task { [weak self] in
            await self?.run()
        }
    }

    func retry(_ id: UUID) {
        update(id) { $0.state = .waiting; $0.attempts = 0; $0.message = nil }
        start()
    }

    func retryAllFailed() {
        for item in items where item.state == .failed { update(item.id) { $0.state = .waiting; $0.attempts = 0; $0.message = nil } }
        start()
    }

    /// Skips a waiting or copying file; the partial copy is thrown away.
    func skip(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), !item.state.isFinished else { return }
        if item.state == .copying {
            stop.request(id)
        } else {
            update(id) { $0.state = .skipped }
            removePartial(id)
            settleWaiters()
        }
    }

    func cancelAll() {
        for item in items where !item.state.isFinished { skip(item.id) }
    }

    func clearFinished() {
        items.removeAll { $0.state.isFinished }
        save()
    }

    var hasWork: Bool { items.contains { !$0.state.isFinished } }

    // MARK: Worker

    private func run() async {
        while let next = items.first(where: { $0.state == .waiting }) {
            let paused = await copy(next)
            onItemFinished?()
            settleWaiters()
            if paused { break }
        }
        worker = nil
        progress = nil
        endBackgroundTime()
        settleWaiters()
    }

    /// Returns true when copying paused (out of background time) and the run should stop.
    private func copy(_ item: Item) async -> Bool {
        update(item.id) { $0.state = .copying; $0.attempts += 1 }
        if !batchIDs.contains(item.id) { batchIDs.append(item.id) }
        let index = (batchIDs.firstIndex(of: item.id) ?? 0) + 1
        let count = batchIDs.count
        let flags = stop
        let id = item.id
        let start = batchStart
        let before = batchBytesBefore
        let sizesAfter = items.filter { $0.state == .waiting && $0.id != id }.map(\.size)

        let outcome = await Task.detached(priority: .userInitiated) { [weak self] in
            var lastSent = Date.distantPast
            return ImportQueue.copy(item, shouldStop: { flags.isRequested(id) }) { done, total in
                let now = Date()
                guard now.timeIntervalSince(lastSent) >= 0.125 else { return }
                lastSent = now
                let rate = Double(before + done) / max(0.001, now.timeIntervalSince(start))
                var remaining = total.map { $0 - done }
                for size in sizesAfter { remaining = remaining.flatMap { r in size.map { r + $0 } } }
                let progress = ROMLibrary.ImportProgress(
                    index: index, count: count, fileName: item.name, bytesDone: done, bytesTotal: total,
                    bytesPerSecond: rate, secondsLeft: rate > 0 ? remaining.map { Double($0) / rate } : nil)
                Task { @MainActor in self?.show(progress, for: id, done: done) }
            }
        }.value
        stop.clear(id)
        progress = nil

        switch outcome {
        case .saved(let name, let bytes):
            batchBytesBefore += bytes
            update(id) { $0.state = .done; $0.savedName = name; $0.message = nil; $0.bytesDone = bytes }
        case .duplicate:
            update(id) { $0.state = .duplicate }
        case .unsupported:
            update(id) { $0.state = .unsupported }
        case .stopped:
            update(id) { $0.state = .skipped }
            removePartial(id)
        case .paused:
            // Not the file's fault: put it back without using up an attempt.
            update(id) { $0.state = .waiting; $0.attempts -= 1 }
            return true
        case .failed(let message):
            log.error("import of \(item.name, privacy: .public) failed (attempt \(item.attempts + 1)): \(message, privacy: .public)")
            let attempts = items.first { $0.id == id }?.attempts ?? Self.maxAttempts
            if attempts < Self.maxAttempts {
                // Leave the partial copy so the retry resumes it; back off a little first.
                update(id) { $0.state = .waiting; $0.message = message }
                try? await Task.sleep(for: .seconds(Double(attempts) * retryDelay))
            } else {
                update(id) { $0.state = .failed; $0.message = message }
                removePartial(id)
            }
        }
        return false
    }

    private func show(_ progress: ROMLibrary.ImportProgress, for id: UUID, done: Int64) {
        guard items.first(where: { $0.id == id })?.state == .copying else { return }
        self.progress = progress
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].bytesDone = done
        }
    }

    private func settleWaiters() {
        waiters.removeAll { waiter in
            let batch = items.filter { waiter.ids.contains($0.id) }
            guard batch.allSatisfy({ $0.state.isFinished }) else { return false }
            waiter.continuation.resume(returning: Self.report(for: batch))
            return true
        }
    }

    private static func report(for batch: [Item]) -> ROMLibrary.ImportReport {
        var report = ROMLibrary.ImportReport()
        for item in batch {
            switch item.state {
            case .done: if let name = item.savedName { report.imported.append(GamePaths.roms.appending(path: name)) }
            case .duplicate: report.duplicates.append(item.name)
            case .unsupported: report.unsupported.append(item.name)
            case .failed, .skipped: report.failed.append(item.name)
            case .waiting, .copying: break
            }
        }
        return report
    }

    // MARK: Helpers

    private func makeItem(_ url: URL) -> Item {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        let bookmark = try? url.bookmarkData()
        return Item(id: UUID(), name: url.lastPathComponent, bookmark: bookmark,
                    path: bookmark == nil ? url.path : nil, size: size)
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        save()
    }

    private func save() {
        // bytesDone is display-only; resuming goes by the partial file's size.
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }

    private func removePartial(_ id: UUID) {
        try? FileManager.default.removeItem(at: Self.partialURL(for: id))
    }

    nonisolated static func partialURL(for id: UUID) -> URL {
        GamePaths.roms.appending(path: ".importing-\(id.uuidString)")
    }

    private func beginBackgroundTime() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Import ROMs") { [weak self] in
            // Out of background time: stop cleanly; the partial file resumes next time.
            Task { @MainActor in
                guard let self else { return }
                for item in self.items where item.state == .copying { self.stop.pause(item.id) }
                self.endBackgroundTime()
            }
        }
    }

    private func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: Copying (off the main actor)

    enum Outcome: Sendable {
        case saved(name: String, bytes: Int64)
        case duplicate, unsupported, stopped, paused
        case failed(String)
    }

    /// Copies one file, resuming a partial copy left by an earlier attempt.
    nonisolated static func copy(_ item: Item, shouldStop: () -> StopFlags.Reason?,
                                 progress: (Int64, Int64?) -> Void) -> Outcome {
        guard ROMLibrary.isROM(URL(filePath: item.name)) else { return .unsupported }
        var source: URL
        if let bookmark = item.bookmark {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else {
                return .failed("The original file can't be found any more.")
            }
            source = url
        } else if let path = item.path {
            source = URL(filePath: path)
        } else {
            return .failed("The original file can't be found any more.")
        }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        var coordinationError: NSError?
        var outcome: Outcome = .failed("Couldn't read the file.")
        // Blocks while iCloud downloads the file, if it has to.
        NSFileCoordinator().coordinate(readingItemAt: source, options: [.withoutChanges],
                                       error: &coordinationError) { readable in
            outcome = copyReadable(readable, item: item, shouldStop: shouldStop, progress: progress)
        }
        if let coordinationError { return .failed(coordinationError.localizedDescription) }
        return outcome
    }

    nonisolated private static func copyReadable(_ source: URL, item: Item, shouldStop: () -> StopFlags.Reason?,
                                                 progress: (Int64, Int64?) -> Void) -> Outcome {
        let fm = FileManager.default
        let total = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        let partial = partialURL(for: item.id)
        var resumeFrom = (try? fm.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
        if let total, resumeFrom > total { resumeFrom = 0 }

        // An identical file already in the library (checked before a fresh copy only).
        let existing = GamePaths.roms.appending(path: item.name)
        if resumeFrom == 0, fm.fileExists(atPath: existing.path), fm.contentsEqual(atPath: existing.path, andPath: source.path) {
            return .duplicate
        }
        do {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            if resumeFrom == 0 || !fm.fileExists(atPath: partial.path) {
                resumeFrom = 0
                guard fm.createFile(atPath: partial.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            }
            let output = try FileHandle(forWritingTo: partial)
            defer { try? output.close() }
            try input.seek(toOffset: UInt64(resumeFrom))
            try output.truncate(atOffset: UInt64(resumeFrom))
            try output.seekToEnd()
            var done = resumeFrom
            progress(done, total)
            while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
                switch shouldStop() {
                case .skip?: return .stopped
                case .pause?: return .paused
                case nil: break
                }
                try output.write(contentsOf: chunk)
                done += Int64(chunk.count)
                progress(done, total)
            }
            try output.synchronize()
            if let total, done != total { return .failed("The copy came out the wrong size.") }

            let base = (item.name as NSString).deletingPathExtension
            let ext = (item.name as NSString).pathExtension
            var destination = existing
            var counter = 2
            while fm.fileExists(atPath: destination.path) {
                destination = GamePaths.roms.appending(path: "\(base) (\(counter)).\(ext)")
                counter += 1
            }
            try fm.moveItem(at: partial, to: destination)
            return .saved(name: destination.lastPathComponent, bytes: done)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// Lock-protected stop requests the copying thread polls between chunks.
final class StopFlags: @unchecked Sendable {
    enum Reason { case skip, pause }
    private let lock = NSLock()
    private var reasons: [UUID: Reason] = [:]

    func request(_ id: UUID) { lock.withLock { reasons[id] = .skip } }
    func pause(_ id: UUID) { lock.withLock { reasons[id] = .pause } }
    func clear(_ id: UUID) { lock.withLock { reasons[id] = nil } }
    func isRequested(_ id: UUID) -> Reason? { lock.withLock { reasons[id] } }
}
