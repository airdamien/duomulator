import UIKit
import os

// MARK: - Manual override

/// User-selectable layout override, stored in UserDefaults "postureOverride". Useful when a
/// tray table holds the hinge at an odd angle, and for testing the tent layout on devices
/// without a hinge (where forceTent splits the screen at its vertical middle).
enum PostureOverride: String, CaseIterable, Sendable {
    case auto, forceTent, forceFlat

    static let defaultsKey = "postureOverride"

    static var current: PostureOverride {
        get {
            UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .auto
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

// MARK: - Posture monitor

/// Tracks hinge state + the fold's division region for a view and reports a `Posture`.
///
/// Inputs are the `UIHingeInteraction` status (iOS 27.1+) and `reservedRegions(kind: .division)`.
/// UIKit has no notification or trait for reserved-region changes, so regions are re-queried on
/// every `refresh()` (call it from viewDidLayoutSubviews) and after every hinge update.
///
/// Changes between posture *kinds* (tent / flat / closed) are debounced so a hinge hovering at
/// a status threshold doesn't flap the layout; geometry-only changes within `.tent` (rotation,
/// resize) apply immediately so layout always tracks the real fold. `onChange` is called on
/// the main thread only when `posture` actually changes.
@MainActor
final class PostureMonitor {
    private(set) var posture: Posture = .flat
    var onChange: ((Posture) -> Void)?

    /// How long a new posture kind must persist before it is reported.
    var debounceInterval: TimeInterval = 0.15

    /// Persisted manual override; setting it re-evaluates immediately (no debounce).
    var override: PostureOverride {
        get { PostureOverride.current }
        set {
            PostureOverride.current = newValue
            pendingChange?.cancel()
            pendingChange = nil
            apply(evaluate())
        }
    }

    /// Hinge state as last reported, mirrored into a type that exists on iOS 26.
    enum HingeState: Equatable, Sendable {
        /// No hinge: not a foldable, or the view left a hierarchy that provides hinge updates.
        case none
        case unknown, closed, partiallyOpen, fullyOpen
    }
    private(set) var hingeState: HingeState = .none
    /// Hinge angle in radians, when a hinge is reported.
    private(set) var hingeAngle: CGFloat?

    /// Whether the device reported a hinge at any point; lets the UI word layout options.
    private(set) var hasHinge = false

    /// Frames of active `.occlusion` regions (cameras etc.) in the view's coordinates. Empty
    /// before iOS 27.1. Updated on every refresh.
    private(set) var occlusionFrames: [CGRect] = []

    /// The fold's frame as last queried (active or not), whatever the posture.
    private(set) var fold: CGRect?

    private weak var view: UIView?
    private var interaction: UIInteraction?
    private var pendingChange: Task<Void, Never>?
    private var followUp: Task<Void, Never>?
    private var hasReceivedHinge = false
    private let log = Logger(subsystem: "io.kurast.duomulator", category: "posture")

    init(view: UIView) {
        self.view = view
        if #available(iOS 27.1, *) {
            let hinge = UIHingeInteraction { [weak self] _, update in
                self?.hingeDidUpdate(update.hinge)
            }
            view.addInteraction(hinge)
            interaction = hinge
        }
        posture = evaluate()
    }

    /// Re-evaluate (call from viewDidLayoutSubviews).
    func refresh() {
        let candidate = evaluate()
        if candidate == posture {
            // Back where we started: whatever was pending was a flap.
            pendingChange?.cancel()
            pendingChange = nil
            return
        }
        if candidate.kind == posture.kind {
            // Same posture, new geometry (rotation / resize): follow it right away.
            pendingChange?.cancel()
            pendingChange = nil
            apply(candidate)
            return
        }
        scheduleDebouncedChange()
    }

    /// Stops observing the hinge.
    func invalidate() {
        pendingChange?.cancel()
        followUp?.cancel()
        if let interaction, let view { view.removeInteraction(interaction) }
        interaction = nil
        onChange = nil
    }

    // MARK: Hinge

    @available(iOS 27.1, *)
    private func hingeDidUpdate(_ hinge: UIHinge?) {
        if let hinge {
            hasHinge = true
            hingeAngle = hinge.angle
            switch hinge.status {
            case .closed: hingeState = .closed
            case .partiallyOpen: hingeState = .partiallyOpen
            case .fullyOpen: hingeState = .fullyOpen
            default: hingeState = .unknown
            }
        } else {
            hingeState = .none
            hingeAngle = nil
        }
        log.debug("hinge \(String(describing: self.hingeState)) angle \(Double(self.hingeAngle ?? -1))")
        if !hasReceivedHinge {
            // The first update is the initial state, not a transition: no debounce, so the
            // game opens straight into the right layout.
            hasReceivedHinge = true
            pendingChange?.cancel()
            pendingChange = nil
            apply(evaluate())
        } else {
            refresh()
        }
        view?.setNeedsLayout()
        // Reserved regions can settle a moment after the hinge status does, and nothing
        // signals that, so look again once things have had time to settle.
        followUp?.cancel()
        followUp = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.refresh()
            self.view?.setNeedsLayout()
        }
    }

    // MARK: Evaluation

    private func scheduleDebouncedChange() {
        guard pendingChange == nil else { return }
        let delay = debounceInterval
        pendingChange = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.pendingChange = nil
            // Re-read at fire time: only a posture that is still current wins.
            self.apply(self.evaluate())
        }
    }

    private func apply(_ new: Posture) {
        guard new != posture else { return }
        log.debug("posture \(String(describing: self.posture)) -> \(String(describing: new))")
        posture = new
        onChange?(new)
    }

    private func evaluate() -> Posture {
        guard let view else { return .flat }
        let division = queryRegions(in: view)
        fold = division
        // Only a fold across the screen splits it: half-open sideways (fold running top to
        // bottom) isn't a way to play, and the game screen rotates out of it.
        let crossFold = division.flatMap { $0.width >= $0.height ? $0 : nil }

        switch PostureOverride.current {
        case .forceFlat:
            return .flat
        case .forceTent:
            if let crossFold { return .tent(division: crossFold) }
            // No fold across the screen to use (regular phone, or the fold is inactive): split at the middle.
            let b = view.bounds
            return .tent(division: CGRect(x: b.minX, y: b.midY, width: b.width, height: 0).integral)
        case .auto:
            switch hingeState {
            case .partiallyOpen:
                if let crossFold, isActiveDivision { return .tent(division: crossFold) }
                return .flat
            case .closed:
                return .closed
            case .fullyOpen, .unknown, .none:
                return .flat
            }
        }
    }

    /// Whether the division frame returned by the last `queryRegions` was an active region.
    private var isActiveDivision = false

    /// Queries reserved regions; returns the division to split at (preferring an active one,
    /// falling back to an inactive one so forceTent on a Duo still uses the real fold) and
    /// updates `occlusionFrames`.
    private func queryRegions(in view: UIView) -> CGRect? {
        isActiveDivision = false
        guard #available(iOS 27.1, *) else {
            occlusionFrames = []
            return nil
        }
        occlusionFrames = view.reservedRegions(kind: .occlusion)
            .filter { $0.isActive && !$0.frame.isEmpty }
            .map(\.frame)
        let divisions = view.reservedRegions(kind: .division, options: .includeInactive)
            .filter { !$0.frame.isNull && !$0.frame.isInfinite }
        if let active = divisions.first(where: \.isActive) {
            isActiveDivision = true
            return active.frame
        }
        return divisions.first?.frame
    }
}

extension Posture {
    /// Posture with the geometry stripped, for "did the kind of layout change" comparisons.
    enum Kind: Equatable { case closed, tent, flat }

    var kind: Kind {
        switch self {
        case .closed: .closed
        case .tent: .tent
        case .flat: .flat
        }
    }

    var division: CGRect? {
        if case .tent(let division) = self { return division }
        return nil
    }
}
