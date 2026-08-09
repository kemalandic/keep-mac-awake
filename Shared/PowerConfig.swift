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
struct SleepBlocker: Codable, Equatable, Hashable {
    /// The process holding the assertion, e.g. "caffeinate".
    let process: String
    /// The kind of sleep it prevents, as macOS names it.
    let assertion: String
    /// The description the holder gave, e.g. "caffeinate command-line tool".
    let reason: String

    /// The case that explains "the screen never turns off".
    var keepsDisplayOn: Bool { assertion == "PreventUserIdleDisplaySleep" }

    /// The name the user would recognise.
    ///
    /// Some processes hold assertions on behalf of others — `runningboardd`
    /// does it for background tasks the way `powerd` does for the system. The
    /// broker's name tells the user nothing; the app they know is buried in the
    /// description, alongside internal bookkeeping that has no business on
    /// screen.
    var displayName: String { brokeredApp ?? process }

    /// One short line under the name.
    ///
    /// For a brokered assertion this is who is holding it, because the raw
    /// description is internal bookkeeping — instance identifiers, a user id,
    /// an assertion number — that means nothing to the user and should not be
    /// displayed. Otherwise the holder's own description is the most useful
    /// thing there is, trimmed so a verbose one cannot wrap across the window.
    var displayDetail: String {
        guard brokeredApp == nil else { return "via \(process)" }
        return Self.shortened(reason)
    }

    /// The last component of a bundle identifier in the description, when the
    /// holder is standing in for something else. `com.apple.Safari` → `Safari`.
    private var brokeredApp: String? {
        let candidates = reason
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
            .filter { $0.filter { $0 == "." }.count >= 2 }

        guard let identifier = candidates.first(where: { !$0.hasPrefix("application.") }),
              let name = identifier.split(separator: ".").last,
              String(name) != process
        else { return nil }

        return String(name)
    }

    private static let detailLimit = 80

    private static func shortened(_ text: String) -> String {
        guard text.count > detailLimit else { return text }
        return text.prefix(detailLimit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// One entry per thing holding the Mac awake.
    ///
    /// A process can hold several assertions of the same kind with the same
    /// description — two `caffeinate -d` runs do exactly that. Listing them
    /// separately says nothing the first row did not, and leaves rows that
    /// cannot be told apart. What is kept separate is the *kind*: holding the
    /// display on and holding the system awake are different answers to "why is
    /// my Mac like this", even from the same process.
    static func summarised(_ blockers: [SleepBlocker]) -> [SleepBlocker] {
        var seen = Set<String>()
        return blockers.filter { seen.insert("\($0.displayName)|\($0.assertion)").inserted }
    }
}
