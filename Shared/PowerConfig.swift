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
