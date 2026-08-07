import Foundation

/// The app's own preferences — and only those.
///
/// The power settings are NOT here: they live in the system, written by the
/// helper, and read back from it. A second copy would only drift from it.
struct Preferences {
    private enum Key {
        static let launchAtLogin = "launchAtLogin"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Key.launchAtLogin) }
        nonmutating set { defaults.set(newValue, forKey: Key.launchAtLogin) }
    }
}
