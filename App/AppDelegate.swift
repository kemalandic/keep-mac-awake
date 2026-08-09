import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let helper = PowerHelperClient()
    private let preferences = Preferences()

    private var menuController: MenuController!
    private var settingsWindow: SettingsWindowController?

    /// Mirrors what the system reports. Never a wish, always the truth we last read.
    private var config = PowerConfig.off

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        Log.app.notice("app launched — version \(version, privacy: .public)")
        guard !terminateIfAlreadyRunning() else {
            Log.app.notice("another copy is already running — quitting")
            return
        }

        menuController = MenuController(
            onToggleKeepAwake: { [weak self] on in
                self?.change { $0.keepAwake = on }
            },
            onToggleDisplay: { [weak self] on in
                self?.change { $0.keepDisplayOn = on }
            },
            onToggleLidClosed: { [weak self] on in
                self?.change { $0.stayAwakeWithLidClosed = on }
            },
            onOpenSettings: { [weak self] in self?.showSettings() }
        )
        menuController.install()

        refreshFromSystem()
    }

    // Deliberately no applicationWillTerminate: quitting must change nothing.

    /// A second copy would fight the first over the same system state.
    private func terminateIfAlreadyRunning() -> Bool {
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: HelperConstants.appBundleID)
            .filter { $0 != .current }

        guard let existing = others.first else { return false }
        existing.activate()
        NSApp.terminate(nil)
        return true
    }

    // MARK: - Reading the machine

    /// Ask the system what it currently has.
    ///
    /// Without a helper we cannot read the settings — but they are still in
    /// effect, so the menu says "unknown" rather than "off". Showing off here
    /// is what makes a user turn everything off, watch nothing change, and
    /// conclude the app does not work.
    private func refreshFromSystem() {
        Task { @MainActor in
            await repairBrokenHelper()
            await replaceStaleHelper()

            guard await helper.isReachable(), let current = await helper.currentConfig() else {
                Log.app.notice("helper unreachable — settings unknown")
                menuController.show(.unknown)
                return
            }
            config = current
            menuController.show(.known(current))
            Log.app.notice("""
            system reports keepAwake=\(current.keepAwake, privacy: .public) \
            display=\(current.keepDisplayOn, privacy: .public) \
            lid=\(current.stayAwakeWithLidClosed, privacy: .public)
            """)
        }
    }

    /// Fixes a registration that exists but cannot start, without waiting to be
    /// asked. The usual cause is an ordinary update: replacing the app bundle
    /// invalidates the bookmark the registration holds, so launchd can no
    /// longer find the daemon's binary and the job fails on every attempt.
    ///
    /// Only done when a registration is actually there. A machine with no
    /// registration at all has not agreed to anything yet, and installing a
    /// privileged helper is not something to do behind the user's back.
    private func repairBrokenHelper() async {
        let state = await helper.installationState()
        Log.app.notice("helper state at launch: \(String(describing: state), privacy: .public)")
        guard state == .broken else { return }

        Log.app.notice("helper registered but not starting — repairing")
        do {
            try await helper.reregister()
            Log.app.notice("helper repaired")
        } catch {
            Log.app.error("repair failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Replacing the app leaves the previously launched helper running from the
    /// old binary, so a fix shipped in the app would never reach the machine.
    /// Compare versions and restart it when they differ.
    private func replaceStaleHelper() async {
        guard await helper.isReachable() else { return }

        let appVersion = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        guard let running = await helper.helperVersion(), running != appVersion else { return }

        Log.app.notice("helper is stale (app \(appVersion, privacy: .public), running \(running, privacy: .public)) — restarting it")
        do {
            try await helper.reregister()
            Log.app.notice("helper restarted")
        } catch {
            // Not silent: a failure here can leave the machine with no
            // registered helper, and the user is the only one who can tell
            // whether that matters right now.
            Log.app.error("could not restart helper: \(error.localizedDescription, privacy: .public)")
            presentError("""
            Keep Mac Awake could not restart its helper after the update: \
            \(error.localizedDescription)

            Open Settings and use Repair to try again.
            """)
        }
    }

    // MARK: - Writing

    private func change(_ mutate: @escaping (inout PowerConfig) -> Void) {
        var wanted = config
        mutate(&wanted)
        apply(wanted)
    }

    private func apply(_ wanted: PowerConfig) {
        Task { @MainActor in
            do {
                try await helper.prepareHelper()
            } catch PowerHelperError.needsApproval {
                presentApprovalPrompt(then: wanted)
                return
            } catch {
                presentError("Could not set up the helper: \(error.localizedDescription)")
                return
            }

            do {
                try await helper.apply(wanted)
                config = wanted
                menuController.show(.known(wanted))
            } catch {
                presentError(error.localizedDescription)
                refreshFromSystem()
            }
        }
    }

    // MARK: - Installing

    /// Installs the helper, or repairs a registration that went missing while
    /// the daemon kept running.
    ///
    /// Deliberately not `prepareHelper()`: that returns early as soon as the
    /// helper answers, and a helper that answers without being registered is
    /// precisely the case this has to fix.
    @MainActor
    private func registerHelper() async {
        do {
            try await helper.reregister()
            Log.app.notice("helper registered on request")
            refreshFromSystem()
        } catch {
            Log.app.error("registration failed: \(error.localizedDescription, privacy: .public)")
            presentError(error.localizedDescription)
        }
    }

    // MARK: - Approval

    private func presentApprovalPrompt(then wanted: PowerConfig) {
        let alert = NSAlert()
        alert.messageText = "One-time approval needed"
        alert.informativeText = """
        macOS needs your approval before Keep Mac Awake can change power \
        settings. This is a one-time step — you will not be asked again.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        helper.openLoginItemsSettings()

        Task { @MainActor in
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(1))
                guard await helper.isReachable() else { continue }
                Log.app.notice("approval detected — applying")
                apply(wanted)
                return
            }
            Log.app.notice("gave up waiting for approval")
        }
    }

    // MARK: - Feedback

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Keep Mac Awake"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Settings

    private func showSettings() {
        if let settingsWindow {
            settingsWindow.present()
            return
        }

        let view = SettingsView(
            preferences: preferences,
            currentHelperState: { [helper] in await helper.installationState() },
            currentBlockers: { [helper] in await helper.sleepBlockers() },
            onInstallHelper: { [weak self] in await self?.registerHelper() },
            onRemoveHelper: { [weak self] in
                guard let self else { return }
                // Put the machine back before removing the only thing that
                // can put it back.
                if self.config != .off {
                    try? await self.helper.apply(.off)
                    self.config = .off
                    self.menuController.show(.known(.off))
                }
                try? await self.helper.uninstall()
            },
            onRestoreDefaults: { [weak self] in
                guard let self else { return }
                do {
                    try await self.helper.restoreDefaults()
                    Log.app.notice("macOS defaults restored")
                    self.config = .off
                    self.refreshFromSystem()
                } catch {
                    Log.app.error("restore failed: \(error.localizedDescription, privacy: .public)")
                    self.presentError(error.localizedDescription)
                }
            }
        )
        let controller = SettingsWindowController(rootView: view)
        settingsWindow = controller
        controller.present()
    }
}
