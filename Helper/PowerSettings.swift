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
