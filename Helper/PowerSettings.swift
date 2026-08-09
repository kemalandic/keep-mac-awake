import Foundation

/// The three `pmset` values this app touches, as the machine currently has them.
struct PowerSettings: Codable, Equatable {
    /// Idle system sleep in minutes; 0 means never.
    var sleepMinutes: Int
    /// Idle display sleep in minutes; 0 means never.
    var displaySleepMinutes: Int
    /// System-wide lid-close override.
    var disableSleep: Bool
}

enum PmsetOutput {
    /// `pmset -g` omits the SleepDisabled line entirely until the setting has
    /// been written at least once. Absent means off.
    static func parse(_ output: String) -> PowerSettings {
        PowerSettings(
            sleepMinutes: integer(named: "sleep", in: output) ?? 0,
            displaySleepMinutes: integer(named: "displaysleep", in: output) ?? 0,
            disableSleep: (integer(named: "sleepdisabled", in: output)
                           ?? integer(named: "disablesleep", in: output)
                           ?? 0) == 1
        )
    }

    /// Who is holding the Mac awake, from `pmset -g assertions`.
    ///
    /// Only the assertions that actually prevent sleep count, and only when
    /// something other than the operating system holds them:
    ///
    /// - `powerd` asserts "Prevent sleep while display is on" on every Mac
    ///   whose screen is lit. Reporting the OS's own bookkeeping would be noise
    ///   on a healthy machine and would bury the real culprit.
    /// - `UserIsActive` means someone touched the keyboard. Not a reason the
    ///   machine is refusing to sleep.
    ///
    /// Owner lines look like:
    ///
    ///     pid 73062(caffeinate): [0x…] 00:00:02 PreventUserIdleDisplaySleep named: "caffeinate command-line tool"
    ///
    /// and are followed by tab-indented detail lines, which must not be
    /// mistaken for assertions of their own.
    static func parseAssertions(_ output: String) -> [SleepBlocker] {
        let preventing = ["PreventUserIdleDisplaySleep",
                          "PreventUserIdleSystemSleep",
                          "PreventSystemSleep"]

        return output.split(separator: "\n").compactMap { line -> SleepBlocker? in
            let text = String(line)
            guard text.contains("pid "),
                  let open = text.firstIndex(of: "("),
                  let close = text[open...].firstIndex(of: ")")
            else { return nil }

            let process = String(text[text.index(after: open)..<close])
            guard process != "powerd" else { return nil }

            guard let assertion = preventing.first(where: { text.contains($0) })
            else { return nil }

            // Everything between the first and last quote: the description can
            // itself contain quotes, and taking the last one keeps it whole.
            var reason = ""
            if let first = text.firstIndex(of: "\""),
               let last = text.lastIndex(of: "\""), first < last {
                reason = String(text[text.index(after: first)..<last])
            }

            return SleepBlocker(process: process, assertion: assertion, reason: reason)
        }
    }

    /// Values can carry trailing commentary, e.g.
    /// `sleep  0 (sleep prevented by powerd, caffeinate)` — take the first field.
    ///
    /// Keep scanning when the value is not a number: `pmset -g` also contains
    /// `Sleep On Power Button 1`, whose first field lowercases to "sleep" too.
    private static func integer(named key: String, in output: String) -> Int? {
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count > 1, fields[0].lowercased() == key else { continue }
            if let value = Int(fields[1]) { return value }
        }
        return nil
    }
}

protocol PowerSettingsControlling {
    func read() throws -> PowerSettings
    func write(_ settings: PowerSettings) throws
    /// Hands the power settings back to macOS, whatever its defaults are for
    /// this machine. Not something this app can compute: the defaults differ by
    /// model and power source.
    func restoreDefaults() throws
    /// Who, other than the settings, is holding the Mac awake right now.
    func readAssertions() throws -> [SleepBlocker]
}

/// IOPMSetSystemPowerSetting is not in the public SDK, so we drive /usr/bin/pmset.
/// This only ever runs inside the root helper, so no authorization is involved.
///
/// `-a` writes every power profile (battery, AC, UPS), which is what makes the
/// change survive unplugging the charger — and rebooting.
final class PmsetControl: PowerSettingsControlling {
    enum Failure: LocalizedError, Equatable {
        case launchFailed(String)
        case nonZeroExit(Int32, String)

        var errorDescription: String? {
            switch self {
            case .launchFailed(let message):
                return "Could not run pmset: \(message)"
            case .nonZeroExit(let code, let output):
                return "pmset exited with code \(code): \(output)"
            }
        }
    }

    func read() throws -> PowerSettings {
        PmsetOutput.parse(try run(["-g"]))
    }

    func write(_ settings: PowerSettings) throws {
        let current = try read()

        // Only touch what actually differs, so we never write settings the user
        // did not ask us to change.
        if current.sleepMinutes != settings.sleepMinutes {
            _ = try run(["-a", "sleep", String(settings.sleepMinutes)])
        }
        if current.displaySleepMinutes != settings.displaySleepMinutes {
            _ = try run(["-a", "displaysleep", String(settings.displaySleepMinutes)])
        }
        if current.disableSleep != settings.disableSleep {
            _ = try run(["-a", "disablesleep", settings.disableSleep ? "1" : "0"])
        }
    }

    /// `restoredefaults` is a command, not a setting — it takes no `-a`.
    func restoreDefaults() throws {
        _ = try run(["restoredefaults"])
    }

    func readAssertions() throws -> [SleepBlocker] {
        PmsetOutput.parseAssertions(try run(["-g", "assertions"]))
    }

    @discardableResult
    private func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(error.localizedDescription)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)

        guard process.terminationStatus == 0 else {
            throw Failure.nonZeroExit(process.terminationStatus, output)
        }
        return output
    }
}
