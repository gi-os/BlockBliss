import Foundation
import Observation
import UIKit

/// User preferences, stored in UserDefaults and mirrored into the sound and haptics engines.
@Observable @MainActor
final class Settings {
    private enum Key {
        static let sound = "settings.sound"
        static let vibration = "settings.vibration"
        static let reduceEffects = "settings.reduceEffects"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var soundEnabled: Bool {
        didSet {
            defaults.set(soundEnabled, forKey: Key.sound)
            SoundEngine.shared.isEnabled = soundEnabled
        }
    }

    var vibrationEnabled: Bool {
        didSet {
            defaults.set(vibrationEnabled, forKey: Key.vibration)
            Haptics.shared.isEnabled = vibrationEnabled
        }
    }

    /// Fewer particles, no screen shake, shorter animations. Follows the system Reduce Motion setting
    /// until the player chooses otherwise.
    var reduceEffects: Bool {
        didSet { defaults.set(reduceEffects, forKey: Key.reduceEffects) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        soundEnabled = defaults.object(forKey: Key.sound) as? Bool ?? true
        vibrationEnabled = defaults.object(forKey: Key.vibration) as? Bool ?? true
        reduceEffects = defaults.object(forKey: Key.reduceEffects) as? Bool ?? UIAccessibility.isReduceMotionEnabled
        // didSet does not run inside init, so push the loaded values explicitly.
        SoundEngine.shared.isEnabled = soundEnabled
        Haptics.shared.isEnabled = vibrationEnabled
    }
}
