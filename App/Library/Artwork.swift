import UIKit
import os

private let log = Logger(subsystem: "io.kurast.duomulator", category: "artwork")

// MARK: - Store

/// Library thumbnails, kept on this device only (Application Support/Artwork):
/// - `.resume`: the last frame on screen when the player left the game
/// - `.title`: a title-screen frame, captured by running the game briefly in the background
/// - `.boxart`: box art downloaded from a community source (opt-in, see ArtworkSettings)
enum ArtworkKind: String, CaseIterable, Sendable { case boxart, title, resume }

final class ArtworkStore: @unchecked Sendable {
    static let shared = ArtworkStore()
    /// Posted on the main thread when a ROM's artwork changes; `object` is the ROM file name.
    static let didChange = Notification.Name("ArtworkStoreDidChange")

    let root: URL
    private let cache = NSCache<NSString, UIImage>()

    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Artwork", directoryHint: .isDirectory)) {
        self.root = root
        for kind in ArtworkKind.allCases {
            try? FileManager.default.createDirectory(at: root.appending(path: kind.rawValue),
                                                     withIntermediateDirectories: true)
        }
    }

    /// ROM file names are unique within the ROMs folder, so they key the artwork.
    func url(_ kind: ArtworkKind, for rom: URL) -> URL {
        root.appending(path: kind.rawValue).appending(path: rom.lastPathComponent + ".png")
    }

    func has(_ kind: ArtworkKind, for rom: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(kind, for: rom).path)
    }

    func image(_ kind: ArtworkKind, for rom: URL) -> UIImage? {
        let key = url(kind, for: rom).path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = UIImage(contentsOfFile: key as String) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// Best available thumbnail. Library rows prefer box art, then the title screen; Recently
    /// Played prefers where the player left off.
    func thumbnail(for rom: URL, preferResume: Bool) -> (image: UIImage, kind: ArtworkKind)? {
        let order: [ArtworkKind] = preferResume ? [.resume, .boxart, .title] : [.boxart, .title, .resume]
        for kind in order where kind != .boxart || ArtworkSettings.downloadsEnabled {
            if let image = image(kind, for: rom) { return (image, kind) }
        }
        return nil
    }

    func save(_ image: UIImage, _ kind: ArtworkKind, for rom: URL) {
        let file = url(kind, for: rom)
        guard let data = image.pngData() else { return }
        do {
            try data.write(to: file, options: .atomic)
            cache.setObject(image, forKey: file.path as NSString)
        } catch {
            log.error("saving \(kind.rawValue, privacy: .public) art failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let name = rom.lastPathComponent
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: name) }
    }

    /// Moves artwork along with a renamed ROM.
    func move(from old: URL, to new: URL) {
        for kind in ArtworkKind.allCases where has(kind, for: old) {
            try? FileManager.default.moveItem(at: url(kind, for: old), to: url(kind, for: new))
        }
        cache.removeAllObjects()
    }

    func remove(for rom: URL) {
        for kind in ArtworkKind.allCases { try? FileManager.default.removeItem(at: url(kind, for: rom)) }
        cache.removeAllObjects()
    }

    /// Deletes every image of one kind (Settings ▸ Clear Downloaded Artwork).
    func removeAll(_ kind: ArtworkKind) {
        let dir = root.appending(path: kind.rawValue)
        for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
        cache.removeAllObjects()
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }
}

// MARK: - Frame snapshots

enum FrameSnapshot {
    /// The current frame as an image at the system's display shape (DS: top screen only),
    /// or nil before the first frame or when the picture is a single flat color.
    /// `aspect` overrides the system's display shape (arcade games report their own).
    static func image(from frameBuffer: FrameBuffer, system: GameSystem, aspect fixed: CGFloat? = nil) -> UIImage? {
        frameBuffer.withLatestFrame { frame, base -> UIImage? in
            guard frame.sequence > 0, frame.width > 0, frame.height > 0 else { return nil }
            let width = frame.width
            let height = system.isDualScreen ? frame.height / 2 : frame.height
            let src = base.assumingMemoryBound(to: UInt16.self)
            var rgba = [UInt32](repeating: 0, count: width * height)
            let first = src[0]
            var uniform = true
            for i in 0..<(width * height) {
                let p = src[i]
                if p != first { uniform = false }
                let r = UInt32(p >> 11) & 0x1F, g = UInt32(p >> 5) & 0x3F, b = UInt32(p) & 0x1F
                // RGBA8 in memory (little-endian 0xAABBGGRR).
                rgba[i] = 0xFF00_0000 | (b << 3 | b >> 2) << 16 | (g << 2 | g >> 4) << 8 | (r << 3 | r >> 2)
            }
            guard !uniform, let cgImage = makeCGImage(rgba, width: width, height: height) else { return nil }

            // Stretch to the display aspect, as the game view does.
            let shown = GameRenderView.displayRect(
                frameWidth: width, frameHeight: height, drawableSize: CGSize(width: 4096, height: 4096),
                scaling: .aspectFit, squarePixels: system.isDualScreen, fixedAspect: fixed ?? system.displayAspect)
            let aspect = shown.height > 0 ? shown.width / shown.height : 4.0 / 3.0
            let outHeight = CGFloat(height)
            let size = CGSize(width: (outHeight * aspect).rounded(), height: outHeight)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(size: size, format: format).image { context in
                context.cgContext.interpolationQuality = .none
                // UIKit's context is flipped relative to Core Graphics.
                context.cgContext.translateBy(x: 0, y: size.height)
                context.cgContext.scaleBy(x: 1, y: -1)
                context.cgContext.draw(cgImage, in: CGRect(origin: .zero, size: size))
            }
        }
    }

    /// Number of distinct colors in a sample of the current frame; a cheap "is anything on
    /// screen" score for picking a title-screen frame.
    static func colorVariety(of frameBuffer: FrameBuffer) -> Int {
        frameBuffer.withLatestFrame { frame, base in
            let src = base.assumingMemoryBound(to: UInt16.self)
            var seen = Set<UInt16>()
            let count = frame.width * frame.height
            var i = 0
            while i < count { seen.insert(src[i]); i += 7 }
            return seen.count
        }
    }

    private static func makeCGImage(_ pixels: [UInt32], width: Int, height: Int) -> CGImage? {
        let data = pixels.withUnsafeBytes { Data($0) } as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

// MARK: - Title-screen capture

/// Captures title-screen thumbnails by running games briefly on a throwaway emulator
/// instance that never reads or writes saves (`EmulatorCore.persistsSaves = false`).
/// One game at a time, newest request first (the rows the player is looking at), and only
/// while no game is being played.
final class TitleCapturer: @unchecked Sendable {
    static let shared = TitleCapturer()

    /// Systems worth capturing in the background. DS (melonDS manages its own save file) and
    /// Sega CD (BIOS, slow disc boot) only get "where you left off" frames.
    static let supported: Set<GameSystem> = [.snes, .nes, .genesis, .sega32x]
    /// Games tried before, so ones without a usable frame aren't re-run every launch.
    private static let attemptedKey = "artworkTitleAttempted"

    private let queue = DispatchQueue(label: "io.kurast.duomulator.title-capture", qos: .utility)
    private let lock = NSLock()
    private var pending: [(rom: URL, system: GameSystem)] = []
    private var isRunning = false
    private var isPaused = false
    private var attempted: Set<String>

    init() {
        attempted = Set(UserDefaults.standard.stringArray(forKey: Self.attemptedKey) ?? [])
    }

    func request(_ rom: URL, system: GameSystem) {
        guard Self.supported.contains(system) else { return }
        lock.withLock {
            guard !attempted.contains(rom.lastPathComponent),
                  !ArtworkStore.shared.has(.title, for: rom) else { return }
            pending.removeAll { $0.rom == rom }
            pending.append((rom, system))
        }
        pump()
    }

    /// Stops starting captures (a game is about to be played). The one in flight stops at
    /// its next batch of frames; the game's own load waits for that batch.
    func pause() { lock.withLock { isPaused = true } }

    func resume() {
        lock.withLock { isPaused = false }
        pump()
    }

    private func pump() {
        let next: (rom: URL, system: GameSystem)? = lock.withLock {
            guard !isRunning, !isPaused, let job = pending.popLast() else { return nil }
            isRunning = true
            return job
        }
        guard let next else { return }
        queue.async { [self] in
            capture(next.rom, system: next.system)
            lock.withLock { isRunning = false }
            pump()
        }
    }

    private var paused: Bool { lock.withLock { isPaused } }

    /// Runs one capture synchronously (internal for tests; normally driven by `request`).
    func capture(_ rom: URL, system: GameSystem) {
        let core = EmulatorCore()
        core.persistsSaves = false
        do {
            try core.load(rom: rom)
        } catch {
            markAttempted(rom)
            return
        }
        defer { core.unload() }

        // Sample every 2 seconds for ~20 seconds. Publisher logos come first and are often
        // colorful too, so take the latest frame that's nearly as busy as the busiest one:
        // usually the title screen that follows the logos.
        var samples: [(variety: Int, image: UIImage)] = []
        for _ in 1...10 {
            if paused { return }   // a game is starting; try again another time
            core.runFrames(120)
            guard core.loadedROM != nil else { return }   // the game took over the core
            let variety = FrameSnapshot.colorVariety(of: core.frameBuffer)
            if variety >= 8, let image = FrameSnapshot.image(from: core.frameBuffer, system: system) {
                samples.append((variety, image))
            }
        }
        let busiest = samples.map(\.variety).max() ?? 0
        let best = samples.last { Double($0.variety) >= Double(busiest) * 0.7 }
        markAttempted(rom)
        if let best { ArtworkStore.shared.save(best.image, .title, for: rom) }
    }

    private func markAttempted(_ rom: URL) {
        let list: [String] = lock.withLock {
            attempted.insert(rom.lastPathComponent)
            return Array(attempted)
        }
        UserDefaults.standard.set(list, forKey: Self.attemptedKey)
    }
}

// MARK: - Box art downloads (opt-in)

enum ArtworkSettings {
    /// Bool, off by default: fetch box art from `sourceURL`.
    static let downloadsEnabledKey = "artworkDownloads"
    /// String: base URL of a libretro-thumbnails-style server.
    static let sourceURLKey = "artworkSourceURL"
    /// Bool, on by default: only download over Wi-Fi.
    static let wifiOnlyKey = "artworkWiFiOnly"
    static let defaultSourceURL = "https://thumbnails.libretro.com"

    static var downloadsEnabled: Bool { UserDefaults.standard.bool(forKey: downloadsEnabledKey) }
    static var wifiOnly: Bool { UserDefaults.standard.object(forKey: wifiOnlyKey) as? Bool ?? true }
    static var sourceURL: URL? {
        let text = UserDefaults.standard.string(forKey: sourceURLKey) ?? defaultSourceURL
        return URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Fetches box art from a libretro-thumbnails-style server: `<base>/<System>/Named_Boxarts/`
/// is a plain directory listing of `<No-Intro name>.png`. The listing is fetched once per
/// system (cached for a month) and ROM names are matched against it by title and region.
actor BoxArtDownloader {
    static let shared = BoxArtDownloader()

    private var listings: [GameSystem: [String]] = [:]
    private var inFlight: Set<URL> = []
    /// ROMs with no match this session (not retried until the next launch).
    private var unmatched: Set<URL> = []

    /// libretro-thumbnails folder names.
    static func folder(for system: GameSystem) -> String {
        switch system {
        case .nes: "Nintendo - Nintendo Entertainment System"
        case .snes: "Nintendo - Super Nintendo Entertainment System"
        case .nds: "Nintendo - Nintendo DS"
        case .genesis: "Sega - Mega Drive - Genesis"
        case .sega32x: "Sega - 32X"
        case .segaCD: "Sega - Mega-CD - Sega CD"
        case .neoGeo, .cps, .arcade: "FBNeo - Arcade Games"
        case .psx: "Sony - PlayStation"
        case .n64: "Nintendo - Nintendo 64"
        }
    }

    func request(_ rom: URL, system: GameSystem) async {
        guard ArtworkSettings.downloadsEnabled, let base = ArtworkSettings.sourceURL,
              !ArtworkStore.shared.has(.boxart, for: rom),
              !inFlight.contains(rom), !unmatched.contains(rom) else { return }
        inFlight.insert(rom)
        defer { inFlight.remove(rom) }

        let systemURL = base.appending(path: Self.folder(for: system)).appending(path: "Named_Boxarts/")
        guard let names = await listing(for: system, at: systemURL),
              let match = Self.bestMatch(for: Self.matchName(for: rom, system: system), in: names) else {
            unmatched.insert(rom)
            return
        }
        do {
            let (data, response) = try await session.data(from: systemURL.appending(path: match + ".png"))
            guard (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data) else {
                unmatched.insert(rom)
                return
            }
            ArtworkStore.shared.save(Self.downscaled(image, maxSide: 300), .boxart, for: rom)
        } catch {
            log.notice("box art download failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private var session: URLSession {
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = !ArtworkSettings.wifiOnly
        config.allowsExpensiveNetworkAccess = !ArtworkSettings.wifiOnly
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }

    private func listing(for system: GameSystem, at url: URL) async -> [String]? {
        if let cached = listings[system] { return cached }
        let cacheFile = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "artwork-listing-\(system.rawValue).txt")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: cacheFile.path),
           let date = attrs[.modificationDate] as? Date, date.timeIntervalSinceNow > -30 * 86_400,
           let text = try? String(contentsOf: cacheFile, encoding: .utf8) {
            let names = text.split(separator: "\n").map(String.init)
            listings[system] = names
            return names
        }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let names = Self.parseListing(String(decoding: data, as: UTF8.self))
        guard !names.isEmpty else { return nil }
        try? names.joined(separator: "\n").write(to: cacheFile, atomically: true, encoding: .utf8)
        listings[system] = names
        return names
    }

    /// Name to match against the listing: arcade sets go by their full title ("mslug" ->
    /// "Metal Slug - Super Vehicle-001"), everything else by file name.
    static func matchName(for rom: URL, system: GameSystem) -> String {
        if system.isArcade, let entry = ArcadeCatalog.entry(forSet: rom) { return entry.title }
        return rom.deletingPathExtension().lastPathComponent
    }

    /// Image names (without ".png") from an Apache/nginx-style directory listing.
    static func parseListing(_ html: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"href="([^"?/][^"]*)\.png""#)
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap {
            Range($0.range(at: 1), in: html).flatMap { String(html[$0]).removingPercentEncoding }
        }
    }

    /// Best listing name for a ROM file name: same title (`TitleMatching.key`), then the
    /// ROM's region first (GoodTools (U)/(E)/(J) or No-Intro names), avoiding samples,
    /// betas, prototypes and the like, then the fewest extra tags.
    static func bestMatch(for romName: String, in names: [String]) -> String? {
        let key = TitleMatching.key(romName)
        guard !key.isEmpty else { return nil }
        let candidates = names.filter { TitleMatching.key($0) == key }
        guard !candidates.isEmpty else { return nil }
        let regions = preferredRegions(for: romName)
        func score(_ name: String) -> Int {
            let tags = TitleMatching.tags(name)
            let regionTag = tags.first ?? ""
            let regionScore = regions.firstIndex { regionTag.contains($0) } ?? regions.count
            let junk = tags.contains { tag in
                ["Sample", "Beta", "Proto", "Demo", "Kiosk", "Pirate", "Unl"].contains { tag.contains($0) }
            }
            return regionScore * 10 + (junk ? 100 : 0) + tags.count
        }
        return candidates.min { score($0) < score($1) }
    }

    private static func preferredRegions(for romName: String) -> [String] {
        let tags = TitleMatching.tags(romName).joined(separator: " ")
        if tags.contains("USA") || tags == "U" || tags.contains("UE") || tags.contains("JU") || tags.contains("W") {
            return ["USA", "World", "Europe", "Japan"]
        }
        if tags.contains("Europe") || tags == "E" { return ["Europe", "World", "USA", "Japan"] }
        if tags.contains("Japan") || tags == "J" { return ["Japan", "World", "USA", "Europe"] }
        return ["USA", "World", "Europe", "Japan"]
    }

    static func downscaled(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        guard scale < 1 else { return image }
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
