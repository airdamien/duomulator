import UIKit
import os

/// Full-screen gameplay screen. Lays out GameRenderView + TouchControllerView per Posture.
///
/// Owns the play session: loads the ROM into `EmulatorCore.shared`, offers to resume the
/// slot-0 auto-save, runs audio / rendering / controllers, pauses on interruptions, and tears
/// everything down on Quit. Layout is manual (viewDidLayoutSubviews) because it depends on
/// the fold's division frame, which only exists as geometry, not as constraints.
final class GameViewController: UIViewController {
    let rom: URL
    /// Called when the user quits back to the library.
    var onExit: (() -> Void)?

    /// Slot used by the quick-action strip's Save / Load.
    static let quickSlot = 1

    private let core = EmulatorCore.shared
    /// Console of `rom`, known before loading so the first layout is already right.
    private lazy var system = GameSystem.of(rom: rom) ?? .snes
    /// The game (for DS: the top screen).
    private var renderView: GameRenderView!
    /// DS only: the touch screen (bottom half of the same frame) and its touch input.
    private var bottomScreenView: GameRenderView?
    private var touchScreen: DSTouchScreenView?
    private var touchView: TouchControllerView!
    private let quickBar = QuickActionBar()
    private let menuView = GameMenuView()
    private let toast = ToastView()
    private var audio: AudioOutput?
    private var postureMonitor: PostureMonitor!
    private var lastFrames: GameLayout.Frames?

    /// The game has been loaded and the resume/restart choice made; emulation may run.
    private var hasStarted = false
    private var didAttemptLoad = false
    private var isMenuOpen = false
    /// The scene is inactive or backgrounded; emulation stays paused until it returns.
    private var isSuspended = false
    private var hasExited = false
    private var savedIdleTimerDisabled = false
    private var lastLayoutKind: Posture.Kind?
    private var lastControllerConnected = false
    private var observers: [NSObjectProtocol] = []
    private let log = Logger(subsystem: "io.kurast.duomulator", category: "game")

    init(rom: URL) {
        self.rom = rom
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: System chrome

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark

        renderView = GameRenderView(frameBuffer: core.frameBuffer)
        renderView.scaling = GameSettings.scaling
        renderView.fixedAspect = system.displayAspect
        renderView.filter = GameSettings.filter
        view.addSubview(renderView)

        touchView = TouchControllerView(style: .overlay)
        touchView.system = system
        touchView.onMenu = { [weak self] in self?.openMenu() }
        view.addSubview(touchView)

        if system.isDualScreen {
            // Both views read the same stacked frame; each shows one screen, square pixels.
            renderView.region = .topHalf
            renderView.squarePixels = true
            let bottom = GameRenderView(frameBuffer: core.frameBuffer)
            bottom.region = .bottomHalf
            bottom.squarePixels = true
            bottom.scaling = GameSettings.scaling
            bottom.filter = GameSettings.filter
            let touch = DSTouchScreenView()
            touch.screenRect = { [weak bottom] in bottom?.contentRect ?? .zero }
            bottom.addSubview(touch)
            view.addSubview(bottom)   // above the control panel, which flanks it
            bottomScreenView = bottom
            touchScreen = touch
        }

        quickBar.onSave = { [weak self] in self?.quickSave() }
        quickBar.onLoad = { [weak self] in self?.quickLoad() }
        quickBar.onFastForward = { [weak self] in
            guard let self else { return }
            self.setFastForward(!self.core.fastForward)
        }
        quickBar.onMenu = { [weak self] in self?.openMenu() }
        view.addSubview(quickBar)

        view.addSubview(toast)

        configureMenu()
        menuView.isHidden = true
        view.addSubview(menuView)

        postureMonitor = PostureMonitor(view: view)
        postureMonitor.onChange = { [weak self] _ in self?.postureDidChange() }

        let controllers = GameControllerManager.shared
        controllers.onMenu = { [weak self] in
            DispatchQueue.main.async { self?.toggleMenu() }
        }
        controllers.onConnectionChange = { [weak self] connected in
            DispatchQueue.main.async { self?.controllerConnectionDidChange(connected) }
        }
        lastControllerConnected = controllers.isControllerConnected

        observeLifecycle()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        if !didAttemptLoad && !hasExited {
            didAttemptLoad = true
            loadGame()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        postureMonitor.refresh()
        applyLayout()
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Session

    private func loadGame() {
        do {
            try core.load(rom: rom)
        } catch {
            log.error("load failed: \(error.localizedDescription, privacy: .public)")
            let alert = UIAlertController(
                title: "Couldn't Open Game",
                message: "\(rom.lastPathComponent) could not be loaded.\n\n\(error.localizedDescription)",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                self?.exit(unloadCore: false)
            })
            present(alert, animated: true)
            return
        }

        let output = AudioOutput(ring: core.audio, sampleRate: core.sampleRate)
        output.isMuted = GameSettings.muted
        audio = output
        GameControllerManager.shared.start()
        controllerConnectionDidChange(GameControllerManager.shared.isControllerConnected, announce: false)
        savedIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        renderView.startRendering()
        bottomScreenView?.startRendering()

        guard core.hasState(slot: 0) else {
            beginPlaying()
            return
        }
        let alert = UIAlertController(title: "Resume where you left off?", message: nil,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Restart", style: .cancel) { [weak self] _ in
            self?.beginPlaying()
        })
        let resume = UIAlertAction(title: "Resume", style: .default) { [weak self] _ in
            guard let self else { return }
            do {
                try self.core.loadState(slot: 0)
            } catch {
                self.log.error("resume failed: \(error.localizedDescription, privacy: .public)")
                self.toast.show("Couldn't resume — starting fresh")
            }
            self.beginPlaying()
        }
        alert.addAction(resume)
        alert.preferredAction = resume
        present(alert, animated: true)
    }

    private func beginPlaying() {
        hasStarted = true
        updateQuickBar()
        resumeIfAllowed()
    }

    /// Runs emulation + audio unless something (menu, background, alert) wants it paused.
    private func resumeIfAllowed() {
        guard hasStarted, !isMenuOpen, !isSuspended, !hasExited else { return }
        core.resume()
        do {
            try audio?.start()
        } catch {
            log.error("audio start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stops emulation + audio and releases every held button.
    private func pauseEmulation() {
        core.pause()
        audio?.stop()
        InputHub.shared.clearAll()
    }

    private func exit(unloadCore: Bool) {
        guard !hasExited else { return }
        hasExited = true
        if unloadCore {
            core.fastForward = false
            core.unload()
        }
        audio?.stop()
        audio = nil
        renderView.stopRendering()
        bottomScreenView?.stopRendering()
        let controllers = GameControllerManager.shared
        controllers.stop()
        controllers.onMenu = nil
        controllers.onConnectionChange = nil
        InputHub.shared.clearAll()
        postureMonitor.invalidate()
        UIApplication.shared.isIdleTimerDisabled = savedIdleTimerDisabled
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        onExit?()
    }

    // MARK: Interruptions

    private func observeLifecycle() {
        let center = NotificationCenter.default
        let suspend: (Notification) -> Void = { [weak self] note in self?.sceneWillSuspend(note) }
        let wake: (Notification) -> Void = { [weak self] note in self?.sceneDidWake(note) }
        observers = [
            center.addObserver(forName: UIScene.willDeactivateNotification, object: nil, queue: .main, using: suspend),
            center.addObserver(forName: UIScene.didEnterBackgroundNotification, object: nil, queue: .main, using: suspend),
            center.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main, using: wake),
        ]
    }

    /// Only react to our own scene (an iPad-style second scene must not pause this game).
    private func isOurScene(_ note: Notification) -> Bool {
        guard let scene = note.object as? UIScene, let ours = view.window?.windowScene else { return true }
        return scene === ours
    }

    private func sceneWillSuspend(_ note: Notification) {
        guard isOurScene(note), !hasExited else { return }
        let firstTime = !isSuspended
        isSuspended = true
        pauseEmulation()
        // Before the resume prompt is answered the core holds a fresh boot; saving it would
        // overwrite the very state the user is being offered.
        guard hasStarted, firstTime else { return }
        core.flushSRAM()
        do {
            try core.saveState(slot: 0)
        } catch {
            log.error("suspend save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func sceneDidWake(_ note: Notification) {
        guard isOurScene(note), isSuspended, !hasExited else { return }
        isSuspended = false
        if hasStarted && core.loadedROM != nil {
            renderView.startRendering()
            bottomScreenView?.startRendering()
        }
        resumeIfAllowed()
    }

    // MARK: Quick actions

    private func quickSave() {
        guard hasStarted else { return }
        do {
            try core.saveState(slot: Self.quickSlot)
            toast.show("Saved to slot \(Self.quickSlot)")
        } catch {
            toast.show("Save failed")
            log.error("quick save failed: \(error.localizedDescription, privacy: .public)")
        }
        updateQuickBar()
    }

    private func quickLoad() {
        guard hasStarted else { return }
        guard core.hasState(slot: Self.quickSlot) else {
            toast.show("No quick save yet")
            return
        }
        loadState(slot: Self.quickSlot)
    }

    private func loadState(slot: Int) {
        InputHub.shared.clearAll()
        do {
            try core.loadState(slot: slot)
            toast.show("Loaded slot \(slot)")
        } catch {
            toast.show("Load failed")
            log.error("load slot \(slot) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func setFastForward(_ on: Bool) {
        core.fastForward = on
        quickBar.isFastForwarding = on
    }

    private func updateQuickBar() {
        quickBar.isFastForwarding = core.fastForward
        quickBar.canLoad = hasStarted && core.hasState(slot: Self.quickSlot)
    }

    // MARK: Menu

    private func configureMenu() {
        menuView.onResume = { [weak self] in self?.closeMenu() }
        menuView.onSave = { [weak self] slot in
            guard let self else { return }
            do {
                try self.core.saveState(slot: slot)
                self.toast.show("Saved to slot \(slot)")
            } catch {
                self.toast.show("Save failed")
                self.log.error("save slot \(slot) failed: \(error.localizedDescription, privacy: .public)")
            }
            self.closeMenu()
        }
        menuView.onLoad = { [weak self] slot in
            self?.loadState(slot: slot)
            self?.closeMenu()
        }
        menuView.onFastForward = { [weak self] on in self?.setFastForward(on) }
        menuView.onMute = { [weak self] muted in
            GameSettings.muted = muted
            self?.audio?.isMuted = muted
        }
        menuView.onLayout = { [weak self] choice in
            self?.postureMonitor.override = choice
            self?.view.setNeedsLayout()
        }
        menuView.onScaling = { [weak self] scaling in
            GameSettings.scaling = scaling
            self?.renderView.scaling = scaling
            self?.bottomScreenView?.scaling = scaling
        }
        menuView.onFilter = { [weak self] filter in
            GameSettings.filter = filter
            self?.renderView.filter = filter
            self?.bottomScreenView?.filter = filter
        }
        menuView.onReset = { [weak self] in self?.confirmReset() }
        menuView.onQuit = { [weak self] in self?.exit(unloadCore: true) }
    }

    private func menuState() -> GameMenuView.State {
        var dates: [Int: Date] = [:]
        for slot in GameMenuView.slots where core.hasState(slot: slot) {
            let url = GamePaths.state(for: rom, slot: slot)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            dates[slot] = (attributes?[.modificationDate] as? Date) ?? .distantPast
        }
        return GameMenuView.State(
            title: rom.deletingPathExtension().lastPathComponent,
            slotDates: dates,
            fastForward: core.fastForward,
            muted: GameSettings.muted,
            layout: postureMonitor.override,
            scaling: renderView.scaling,
            filter: renderView.filter)
    }

    private func toggleMenu() {
        isMenuOpen ? closeMenu() : openMenu()
    }

    private func openMenu() {
        guard hasStarted, !isMenuOpen, !hasExited, presentedViewController == nil else { return }
        isMenuOpen = true
        pauseEmulation()
        menuView.update(menuState())
        menuView.alpha = 0
        menuView.isHidden = false
        applyLayout()
        UIView.animate(withDuration: 0.18) { self.menuView.alpha = 1 }
        UIAccessibility.post(notification: .screenChanged, argument: menuView)
    }

    private func closeMenu() {
        guard isMenuOpen else { return }
        isMenuOpen = false
        updateQuickBar()
        UIView.animate(withDuration: 0.15, animations: { self.menuView.alpha = 0 }) { _ in
            if !self.isMenuOpen { self.menuView.isHidden = true }
        }
        resumeIfAllowed()
    }

    private func confirmReset() {
        let alert = UIAlertController(title: "Reset the game?",
                                      message: "Unsaved progress since your last save will be lost.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Reset", style: .destructive) { [weak self] _ in
            self?.core.reset()
            self?.closeMenu()
        })
        present(alert, animated: true)
    }

    // MARK: Controllers

    private func controllerConnectionDidChange(_ connected: Bool, announce: Bool = true) {
        guard !hasExited else { return }
        let changed = connected != lastControllerConnected
        lastControllerConnected = connected
        // Buttons held on screen when the pad appears must not stay pressed.
        if connected { InputHub.shared.set([], source: .touch) }
        if announce && changed {
            toast.show(connected ? "Controller connected" : "Controller disconnected")
        }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState]) {
            self.applyLayout()
        }
    }

    // MARK: Layout

    private func postureDidChange() {
        guard isViewLoaded else { return }
        let kind = postureMonitor.posture.kind
        guard kind != lastLayoutKind else {
            // Geometry-only update (e.g. rotation): follow along without extra animation.
            applyLayout()
            return
        }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
            self.applyLayout()
        }
    }

    private func applyLayout() {
        guard renderView != nil else { return }
        let posture = postureMonitor.posture
        let frames = GameLayout.frames(
            system: system,
            posture: posture,
            bounds: view.bounds,
            safeArea: view.safeAreaInsets,
            occlusions: postureMonitor.occlusionFrames,
            // Testing hook (launch argument `-layoutIgnoresGamepads YES`): the Simulator
            // forwards the Mac's paired gamepads, which would otherwise hide the touch controls.
            controllerConnected: lastControllerConnected
                && !UserDefaults.standard.bool(forKey: "layoutIgnoresGamepads"))
        if posture.kind != lastLayoutKind || frames != lastFrames {
            log.notice("layout \(String(describing: posture), privacy: .public) bounds=\(NSCoder.string(for: self.view.bounds), privacy: .public) game=\(NSCoder.string(for: frames.game), privacy: .public) controls=\(frames.controls.map { NSCoder.string(for: $0) } ?? "hidden", privacy: .public)")
        }
        lastLayoutKind = posture.kind
        lastFrames = frames

        renderView.frame = frames.game
        if let bottom = frames.secondScreen {
            bottomScreenView?.frame = bottom
            touchScreen?.frame = bottomScreenView?.bounds ?? .zero
        }
        if let controls = frames.controls {
            if touchView.style != frames.controlStyle { touchView.style = frames.controlStyle }
            touchView.frame = controls
            touchView.reservedRect = frames.secondScreen.map { view.convert($0, to: touchView) }
            touchView.alpha = 1
            touchView.isUserInteractionEnabled = true
        } else {
            touchView.alpha = 0
            touchView.isUserInteractionEnabled = false
            InputHub.shared.set([], source: .touch)
        }
        if let bar = frames.quickBar {
            quickBar.frame = bar
            quickBar.alpha = 1
            quickBar.isUserInteractionEnabled = true
        } else {
            quickBar.alpha = 0
            quickBar.isUserInteractionEnabled = false
        }
        menuView.frame = view.bounds
        menuView.cardArea = frames.menuArea
        toast.anchor = CGPoint(x: frames.game.midX, y: frames.game.minY + 12)
        toast.frame = view.bounds
    }
}

// MARK: - Layout math

/// Pure geometry for GameViewController, kept separate so it's easy to reason about.
enum GameLayout {
    /// SNES output is shown at 4:3 (256x224 with the console's 8:7 pixel aspect).
    static let gameAspect: CGFloat = 4.0 / 3.0
    static let barInset: CGFloat = 12
    static let barMaxWidth: CGFloat = 520

    /// Frames for one layout pass, in the game view controller's view coordinates.
    struct Frames: Equatable {
        var game: CGRect
        /// nil = touch controls hidden (physical controller connected).
        var controls: CGRect?
        var controlStyle: TouchControllerView.Style
        /// nil = no quick-action strip in this layout.
        var quickBar: CGRect?
        /// Where the pause menu card may go.
        var menuArea: CGRect
        /// Dual-screen systems: where the touch screen goes (controls flank it).
        var secondScreen: CGRect? = nil
    }

    static func frames(system: GameSystem = .snes, posture: Posture, bounds: CGRect,
                       safeArea: UIEdgeInsets, occlusions: [CGRect], controllerConnected: Bool)
        -> Frames {
        let safe = bounds.inset(by: safeArea)
        if system.isDualScreen {
            return dualScreen(posture: posture, bounds: bounds, safe: safe, occlusions: occlusions)
        }
        switch posture {
        case .tent(let division):
            return tent(division: division, bounds: bounds, safe: safe, occlusions: occlusions,
                        controllerConnected: controllerConnected)
        case .flat, .closed:
            return flat(bounds: bounds, safe: safe, occlusions: occlusions,
                        controllerConnected: controllerConnected)
        }
    }

    private static func tent(division: CGRect, bounds: CGRect, safe: CGRect, occlusions: [CGRect],
                             controllerConnected: Bool) -> Frames {
        // Game goes on the first side of the fold (top, or leading for a vertical fold),
        // controls on the other. Nothing is placed inside the division frame itself.
        let horizontalFold = division.width >= division.height
        var gameSide: CGRect
        var controlSide: CGRect
        if horizontalFold {
            gameSide = CGRect(x: safe.minX, y: safe.minY,
                              width: safe.width, height: max(0, division.minY - safe.minY))
            controlSide = CGRect(x: bounds.minX, y: division.maxY,
                                 width: bounds.width, height: max(0, bounds.maxY - division.maxY))
        } else {
            gameSide = CGRect(x: safe.minX, y: safe.minY,
                              width: max(0, division.minX - safe.minX), height: safe.height)
            controlSide = CGRect(x: division.maxX, y: bounds.minY,
                                 width: max(0, bounds.maxX - division.maxX), height: bounds.height)
        }
        gameSide = gameSide.avoiding(occlusions)
        controlSide = controlSide.avoiding(occlusions)

        let game = aspectFit(in: gameSide.insetBy(dx: 4, dy: 4))
        // The bar sits at the top of the control half, inside the horizontal safe area.
        let barRow = controlSide.intersection(safe).isNull ? controlSide : controlSide.intersection(safe)
        let barWidth = min(barRow.width - barInset * 2, barMaxWidth)
        let bar = CGRect(x: barRow.midX - barWidth / 2, y: barRow.minY + 8,
                         width: max(0, barWidth), height: QuickActionBar.preferredHeight).integral
        var panel = controlSide
        panel.size.height = max(0, controlSide.maxY - (bar.maxY + 4))
        panel.origin.y = bar.maxY + 4

        let menuArea = controlSide.intersection(safe).height >= 280
            ? controlSide.intersection(safe)
            : safe
        // The half below the fold exists for controls, so they stay even with a gamepad
        // connected (both feed InputHub); hiding them would only leave that half empty.
        return .init(game: game, controls: panel, controlStyle: .panel,
                     quickBar: bar, menuArea: menuArea)
    }

    private static func flat(bounds: CGRect, safe: CGRect, occlusions: [CGRect],
                             controllerConnected: Bool) -> Frames {
        let area = safe.avoiding(occlusions)
        if controllerConnected {
            return .init(game: aspectFit(in: area), controls: nil, controlStyle: .overlay,
                         quickBar: nil, menuArea: safe)
        }
        let portraitish = area.height >= area.width * 1.15
        guard portraitish else {
            // Landscape / squarish: game centered at full height, controls over the gutters.
            return .init(game: aspectFit(in: area), controls: bounds, controlStyle: .overlay,
                         quickBar: nil, menuArea: safe)
        }
        // Portrait: game across the top, controls below it. Cap the game so the controls
        // always keep a comfortable share of the screen.
        let maxGameHeight = area.height * 0.55
        let top = CGRect(x: area.minX, y: area.minY, width: area.width, height: maxGameHeight)
        var game = aspectFit(in: top)
        game.origin.y = area.minY
        var below = CGRect(x: bounds.minX, y: game.maxY,
                           width: bounds.width, height: max(0, bounds.maxY - game.maxY))
        var bar: CGRect?
        let barHeight = QuickActionBar.preferredHeight
        if below.height - barHeight >= 300 {
            let barWidth = min(area.width - barInset * 2, barMaxWidth)
            let r = CGRect(x: area.midX - barWidth / 2, y: below.minY + 8,
                           width: barWidth, height: barHeight).integral
            bar = r
            below.size.height = max(0, below.maxY - (r.maxY + 4))
            below.origin.y = r.maxY + 4
        }
        return .init(game: game, controls: below, controlStyle: .overlay, quickBar: bar, menuArea: safe)
    }

    /// DS: top screen on the upper side of the fold (or of the screen's middle when flat or
    /// closed); below it the quick bar, then the touch screen flanked by the controls. The
    /// controls stay with a gamepad connected (both work), like the half-fold layout.
    private static func dualScreen(posture: Posture, bounds: CGRect, safe: CGRect,
                                   occlusions: [CGRect]) -> Frames {
        var upper: CGRect
        var lower: CGRect
        if case .tent(let division) = posture, division.width >= division.height {
            upper = CGRect(x: safe.minX, y: safe.minY,
                           width: safe.width, height: max(0, division.minY - safe.minY))
            lower = CGRect(x: bounds.minX, y: division.maxY,
                           width: bounds.width, height: max(0, bounds.maxY - division.maxY))
        } else {
            let gap: CGFloat = 6
            upper = CGRect(x: safe.minX, y: safe.minY,
                           width: safe.width, height: max(0, safe.height / 2 - gap))
            lower = CGRect(x: bounds.minX, y: upper.maxY + gap * 2,
                           width: bounds.width, height: max(0, bounds.maxY - upper.maxY - gap * 2))
        }
        upper = upper.avoiding(occlusions)
        lower = lower.avoiding(occlusions)
        let top = aspectFit(in: upper.insetBy(dx: 4, dy: 4))   // a DS screen is 256x192 = 4:3

        let row = lower.intersection(safe).isNull ? lower : lower.intersection(safe)
        let barWidth = min(row.width - barInset * 2, barMaxWidth)
        let bar = CGRect(x: row.midX - barWidth / 2, y: row.minY + 6,
                         width: max(0, barWidth), height: QuickActionBar.preferredHeight).integral
        var panel = lower
        panel.origin.y = bar.maxY + 4
        panel.size.height = max(0, lower.maxY - panel.minY)
        let screenArea = panel.intersection(safe).isNull ? panel : panel.intersection(safe)

        // Leave thumb-sized gutters for the d-pad and face buttons on either side.
        let gutter = min(max(screenArea.width * 0.21, 110), 170)
        let fit = CGRect(x: screenArea.minX + gutter, y: screenArea.minY + 4,
                         width: max(0, screenArea.width - gutter * 2),
                         height: max(0, screenArea.height - 8))
        let bottom = aspectFit(in: fit)
        return .init(game: top, controls: panel, controlStyle: .panel,
                     quickBar: bar, menuArea: safe, secondScreen: bottom)
    }

    /// Largest 4:3 rect centered in `rect`, snapped to whole points.
    static func aspectFit(in rect: CGRect) -> CGRect {
        guard rect.width > 0, rect.height > 0 else { return CGRect(origin: rect.origin, size: .zero) }
        var size = CGSize(width: rect.width, height: rect.width / gameAspect)
        if size.height > rect.height {
            size = CGSize(width: rect.height * gameAspect, height: rect.height)
        }
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                      width: size.width, height: size.height).integral
    }
}

extension CGRect {
    /// Shrinks the rect away from each overlapping obstacle by cutting off whichever edge
    /// loses the least area, so cameras and similar occlusions never cover content.
    func avoiding(_ obstacles: [CGRect]) -> CGRect {
        var r = self
        for o in obstacles {
            let hit = r.intersection(o)
            guard !hit.isNull, hit.width > 0, hit.height > 0 else { continue }
            let candidates = [
                CGRect(x: r.minX, y: o.maxY, width: r.width, height: r.maxY - o.maxY),   // below it
                CGRect(x: r.minX, y: r.minY, width: r.width, height: o.minY - r.minY),   // above it
                CGRect(x: o.maxX, y: r.minY, width: r.maxX - o.maxX, height: r.height),  // right of it
                CGRect(x: r.minX, y: r.minY, width: o.minX - r.minX, height: r.height),  // left of it
            ].filter { $0.width > 0 && $0.height > 0 }
            guard let best = candidates.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
                continue
            }
            r = best
        }
        return r
    }
}

// MARK: - Toast

/// Small transient capsule message ("Saved to slot 1", "Controller connected"). Passes all
/// touches through.
final class ToastView: UIView {
    /// Top-center point of the message, in this view's coordinates.
    var anchor: CGPoint = .zero { didSet { setNeedsLayout() } }

    private let label = PaddedLabel()
    private var hideWork: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.backgroundColor = UIColor(white: 0.1, alpha: 0.85)
        label.layer.cornerRadius = 15
        label.layer.cornerCurve = .continuous
        label.clipsToBounds = true
        label.alpha = 0
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ message: String, duration: TimeInterval = 1.6) {
        label.text = message
        setNeedsLayout()
        layoutIfNeeded()
        UIView.animate(withDuration: 0.15) { self.label.alpha = 1 }
        UIAccessibility.post(notification: .announcement, argument: message)
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.3) { self?.label.alpha = 0 }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = label.sizeThatFits(CGSize(width: bounds.width - 32, height: 30))
        let width = min(size.width, bounds.width - 32)
        label.frame = CGRect(x: anchor.x - width / 2, y: anchor.y, width: width, height: 30).integral
    }

    private final class PaddedLabel: UILabel {
        override func sizeThatFits(_ size: CGSize) -> CGSize {
            let s = super.sizeThatFits(size)
            return CGSize(width: s.width + 28, height: 30)
        }
        override func drawText(in rect: CGRect) {
            super.drawText(in: rect.insetBy(dx: 14, dy: 0))
        }
    }
}
