import UIKit

/// Haptic feedback for the game. One place decides which taps exist, how strong they are, and that none
/// of them fires per frame: every method corresponds to a discrete game event.
///
/// Generators are created once and `prepare()`d ahead of the events that usually follow, so the Taptic
/// Engine is awake when the feedback is needed. Everything is a no-op while `isEnabled` is false (and on
/// devices without a Taptic Engine, where UIKit ignores the calls).
@MainActor
final class Haptics {
    static let shared = Haptics()

    /// Persisted by the app's settings.
    var isEnabled: Bool = true

    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let notification = UINotificationFeedbackGenerator()
    private let selection = UISelectionFeedbackGenerator()

    /// Follow-up taps of a multi-line clear; cancelled when another event takes over.
    private var followUps: [Task<Void, Never>] = []

    private init() {}

    // MARK: Events

    /// Picking a piece up: a light tick. Warms up the generators for the drop that comes next.
    func pickup() {
        guard isEnabled else { return }
        light.impactOccurred(intensity: 0.7)
        medium.prepare()
        rigid.prepare()
    }

    /// A valid drop: a firm but cushioned thud.
    func place() {
        guard isEnabled else { return }
        medium.impactOccurred(intensity: 0.6)
        light.prepare()
    }

    /// A line clear. A single rigid tap whose strength grows with `lines` (1...6); 3+ lines add a
    /// quick second and third pulse so bigger clears feel bigger.
    func clear(lines: Int) {
        guard isEnabled else { return }
        let n = min(max(lines, 1), 6)
        let strength = 0.5 + 0.1 * Double(n - 1)             // 0.5 ... 1.0
        cancelFollowUps()

        rigid.impactOccurred(intensity: strength)
        if n >= 3 { pulse(after: 0.07, intensity: strength * 0.8) }
        if n >= 5 { pulse(after: 0.14, intensity: strength * 0.6) }
        light.prepare()
    }

    /// Board emptied.
    func allClear() {
        guard isEnabled else { return }
        notification.notificationOccurred(.success)
    }

    /// New personal best.
    func newBest() {
        guard isEnabled else { return }
        notification.notificationOccurred(.success)
    }

    /// No moves left: a gentle warning, not a punishment.
    func gameOver() {
        guard isEnabled else { return }
        cancelFollowUps()
        notification.notificationOccurred(.warning)
    }

    /// A drop on an invalid spot: barely-there light tap.
    func invalid() {
        guard isEnabled else { return }
        light.impactOccurred(intensity: 0.35)
    }

    /// A UI button press.
    func tap() {
        guard isEnabled else { return }
        selection.selectionChanged()
    }

    /// Optional warm-up (e.g. when a game screen appears) so the first pick-up has no latency.
    func prepare() {
        guard isEnabled else { return }
        light.prepare()
    }

    // MARK: Helpers

    /// A delayed extra rigid tap that re-checks `isEnabled` when it fires.
    private func pulse(after delay: TimeInterval, intensity: Double) {
        followUps.append(Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.isEnabled else { return }
            self.rigid.impactOccurred(intensity: intensity)
        })
    }

    private func cancelFollowUps() {
        followUps.forEach { $0.cancel() }
        followUps.removeAll()
    }
}
