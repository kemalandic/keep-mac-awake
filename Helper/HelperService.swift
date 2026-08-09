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
    private let desired: DesiredStore
    private let attempts: Int
    private let pause: (TimeInterval) -> Void

    init(control: PowerSettingsControlling,
         store: BaselineStore,
         desired: DesiredStore,
         attempts: Int = 3,
         pause: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.control = control
        self.store = store
        self.desired = desired
        self.attempts = attempts
        self.pause = pause
    }

    /// Hands the power settings back to macOS and gives up ownership.
    ///
    /// The escape hatch from a trap this app can set for itself. The baseline
    /// is captured from whatever the machine happens to have the first time a
    /// switch is flipped; if something had already set `displaysleep 0`, that
    /// gets recorded as "the machine's own value". Switching everything off
    /// then faithfully restores "never sleep" and releases the baseline —
    /// leaving the display on for good, with nothing left in the app to undo.
    ///
    /// Both records go, not just the baseline: a rule left behind would be
    /// re-asserted by the next enforcement pass and quietly undo the restore.
    func restoreDefaults(reply: @escaping (Bool, String?) -> Void) {
        Log.helper.notice("restoring macOS defaults")
        do {
            try control.restoreDefaults()

            // `pmset restoredefaults` restores the per-profile settings and
            // leaves the system-wide lid override exactly as it was. Without
            // this the user is told their Mac was handed back while it still
            // refuses to sleep with the lid closed.
            var settings = try control.read()
            if settings.disableSleep {
                settings.disableSleep = false
                try writeVerified(settings)
            }
        } catch {
            // The records stay. Dropping them after a failed restore would
            // strand the user with settings the app no longer admits to owning.
            Log.helper.error("restore failed: \(error.localizedDescription, privacy: .public)")
            reply(false, error.localizedDescription)
            return
        }

        store.clear()
        desired.clear()
        Log.helper.notice("macOS defaults restored — baseline and rule released")
        reply(true, nil)
    }

    /// Records what is already in effect as the rule, for machines that come
    /// from a version which only wrote settings and never enforced them.
    ///
    /// Those versions left a baseline but no rule, so the switches are on with
    /// nothing to enforce — the user would stay unprotected until they happened
    /// to toggle something. The baseline is the marker that this app owns the
    /// machine's settings: where it exists and no rule does, what is in effect
    /// *is* the rule.
    ///
    /// Without a baseline nothing is claimed. Values on a machine this app
    /// never touched belong to whoever set them.
    func adoptSettingsInEffectAsRule() {
        guard desired.load() == nil, store.exists else { return }
        guard let current = try? control.read() else { return }

        let inEffect = PowerConfig(
            keepAwake: current.sleepMinutes == 0,
            keepDisplayOn: current.displaySleepMinutes == 0,
            stayAwakeWithLidClosed: current.disableSleep
        )
        guard inEffect != .off else { return }

        do {
            try desired.save(inEffect)
            Log.helper.notice("""
            adopted the settings in effect as the rule: \
            keepAwake=\(inEffect.keepAwake, privacy: .public) \
            display=\(inEffect.keepDisplayOn, privacy: .public) \
            lid=\(inEffect.stayAwakeWithLidClosed, privacy: .public)
            """)
        } catch {
            Log.helper.error("could not record the adopted rule: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Puts the user's switches back in effect if anything drifted away from
    /// them. Called on every signal that the power settings may have changed.
    ///
    /// Silent by design when there is nothing to do: this runs often, and a log
    /// line per pass would bury the writes that actually matter.
    func enforce() {
        guard let wanted = desired.load() else { return }
        guard let current = try? control.read() else {
            Log.helper.error("enforce: could not read the current settings")
            return
        }
        guard let correction = PowerEnforcement.correction(for: wanted, given: current) else {
            return
        }

        Log.helper.notice("""
        drift detected — sleep=\(current.sleepMinutes, privacy: .public) \
        displaysleep=\(current.displaySleepMinutes, privacy: .public) \
        disablesleep=\(current.disableSleep, privacy: .public) — reasserting
        """)

        do {
            try writeVerified(correction)
        } catch {
            Log.helper.error("enforce failed: \(error.localizedDescription, privacy: .public)")
        }
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

    func sleepBlockers(reply: @escaping (Data?) -> Void) {
        guard let blockers = try? control.readAssertions() else {
            reply(nil)
            return
        }
        reply(try? PropertyListEncoder().encode(blockers))
    }

    /// Exits, so a registration replacing this one can actually take.
    ///
    /// The reply goes out first and the exit happens a moment later: killing
    /// the process inside the call would drop the reply and look to the app
    /// like a crash. Nothing is reverted on the way out — a setting written
    /// here belongs to the system, not to this process.
    func quit(reply: @escaping (Bool) -> Void) {
        Log.helper.notice("asked to exit — making way for a new registration")
        reply(true)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { exit(0) }
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

        // Written only after the settings actually took: a rule we failed to
        // apply is not a rule worth enforcing on every later pass.
        if config == .off {
            // Fully off means we are done owning the machine's settings.
            store.clear()
            desired.clear()
            Log.helper.notice("everything off — baseline and rule released")
        } else {
            try desired.save(config)
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
