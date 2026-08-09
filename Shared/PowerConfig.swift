import Foundation

/// What the user asked the system to do. These are *system settings*, not a
/// running state: once written they survive quitting the app and rebooting the
/// Mac, exactly like `pmset` from a terminal. Only an explicit change undoes them.
struct PowerConfig: Codable, Equatable {
    /// Never sleep when idle.
    var keepAwake: Bool
    /// Also keep the display on. Off means the screen may sleep while the
    /// system stays up.
    var keepDisplayOn: Bool
    /// Stay awake with the lid closed. Needs `disablesleep`, which is why the
    /// switch can be the first thing to trigger the helper approval prompt.
    var stayAwakeWithLidClosed: Bool

    static let off = PowerConfig(keepAwake: false,
                                 keepDisplayOn: false,
                                 stayAwakeWithLidClosed: false)
}

/// Something other than a power setting is keeping the Mac awake.
///
/// `pmset` writes settings; an `IOPMAssertion` overrides them while it is held.
/// A machine can obey every setting this app writes and still refuse to sleep,
/// with nothing in the settings to explain it — so the holder is worth naming.
struct SleepBlocker: Codable, Equatable {
    /// The process holding the assertion, e.g. "caffeinate".
    let process: String
    /// The kind of sleep it prevents, as macOS names it.
    let assertion: String
    /// The description the holder gave, e.g. "caffeinate command-line tool".
    let reason: String

    /// The case that explains "the screen never turns off".
    var keepsDisplayOn: Bool { assertion == "PreventUserIdleDisplaySleep" }
}
