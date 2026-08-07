import Foundation

/// The entire privileged surface: write power settings, remember the machine's
/// original values so an explicit "off" can restore them.
///
/// It does not track whether the app is running and it never reverts anything on
/// its own. A setting written here behaves like one typed into `pmset`: it stays
/// until someone changes it.
final class HelperService: NSObject, PowerHelperProtocol {
    enum Failure: LocalizedError {
        case settingDidNotStick(PowerSettings, PowerSettings)
        case badRequest

        var errorDescription: String? {
            switch self {
            case .badRequest:
                return "The helper received a request it could not read."
            case .settingDidNotStick(let wanted, let seen):
                return "The system kept sleep=\(seen.sleepMinutes) "
                    + "displaysleep=\(seen.displaySleepMinutes) "
                    + "disablesleep=\(seen.disableSleep ? 1 : 0) instead of "
                    + "sleep=\(wanted.sleepMinutes) "
                    + "displaysleep=\(wanted.displaySleepMinutes) "
                    + "disablesleep=\(wanted.disableSleep ? 1 : 0)."
            }
        }
    }

    private let control: PowerSettingsControlling
    private let store: BaselineStore
    private let attempts: Int
    private let pause: (TimeInterval) -> Void

    init(control: PowerSettingsControlling,
         store: BaselineStore,
         attempts: Int = 3,
         pause: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.control = control
        self.store = store
        self.attempts = attempts
        self.pause = pause
    }

    func apply(_ configData: Data, reply: @escaping (Bool, String?) -> Void) {
        guard let config = try? PropertyListDecoder().decode(PowerConfig.self, from: configData) else {
            Log.helper.error("could not decode config")
            reply(false, Failure.badRequest.localizedDescription)
            return
        }

        Log.helper.notice("""
        apply keepAwake=\(config.keepAwake, privacy: .public) \
        display=\(config.keepDisplayOn, privacy: .public) \
        lid=\(config.stayAwakeWithLidClosed, privacy: .public) \
        hasBaseline=\(self.store.exists, privacy: .public)
        """)

        do {
            try applyConfig(config)
            reply(true, nil)
        } catch {
            Log.helper.error("apply failed: \(error.localizedDescription, privacy: .public)")
            reply(false, error.localizedDescription)
        }
    }

    func currentConfig(reply: @escaping (Data?) -> Void) {
        guard let settings = try? control.read() else {
            reply(nil)
            return
        }
        let config = PowerConfig(
            keepAwake: settings.sleepMinutes == 0,
            keepDisplayOn: settings.displaySleepMinutes == 0,
            stayAwakeWithLidClosed: settings.disableSleep
        )
        reply(try? PropertyListEncoder().encode(config))
    }

    func helperVersion(reply: @escaping (String) -> Void) {
        reply(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0")
    }

    // MARK: - Applying

    private func applyConfig(_ config: PowerConfig) throws {
        let current = try control.read()

        // Capture the machine's own values the first time we change anything.
        if !store.exists {
            try store.save(current)
            Log.helper.notice("""
            baseline captured: sleep=\(current.sleepMinutes, privacy: .public) \
            displaysleep=\(current.displaySleepMinutes, privacy: .public) \
            disablesleep=\(current.disableSleep, privacy: .public)
            """)
        }
        let baseline = store.load() ?? current

        let wanted = PowerSettings(
            sleepMinutes: config.keepAwake ? 0 : baseline.sleepMinutes,
            displaySleepMinutes: config.keepDisplayOn ? 0 : baseline.displaySleepMinutes,
            disableSleep: config.stayAwakeWithLidClosed ? true : baseline.disableSleep
        )

        try writeVerified(wanted)

        // Fully off means we are done owning the machine's settings.
        if config == .off {
            store.clear()
            Log.helper.notice("everything off — baseline released")
        }
    }

    /// pmset can exit 0 without the value taking effect, so read it back.
    private func writeVerified(_ wanted: PowerSettings) throws {
        var seen = wanted

        for attempt in 1...attempts {
            try control.write(wanted)
            seen = try control.read()
            if seen == wanted { return }

            Log.helper.notice("""
            settings did not stick on attempt \(attempt, privacy: .public)/\(self.attempts, privacy: .public) — retrying
            """)
            pause(1)
        }

        throw Failure.settingDidNotStick(wanted, seen)
    }
}
