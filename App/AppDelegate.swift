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
        guard !terminateIfAlreadyRunning() else { return }

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

    /// Ask the system what it currently has. Without a helper we cannot read
    /// the settings, so the menu shows everything off until one is installed.
    private func refreshFromSystem() {
        Task { @MainActor in
            await replaceStaleHelper()

            guard await helper.isReachable(), let current = await helper.currentConfig() else {
                Log.app.notice("helper unreachable — showing defaults")
                return
            }
            config = current
            menuController.show(current)
            Log.app.notice("""
            system reports keepAwake=\(current.keepAwake, privacy: .public) \
            display=\(current.keepDisplayOn, privacy: .public) \
            lid=\(current.stayAwakeWithLidClosed, privacy: .public)
            """)
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
            Log.app.error("could not restart helper: \(error.localizedDescription, privacy: .public)")
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
                menuController.show(wanted)
            } catch {
                presentError(error.localizedDescription)
                refreshFromSystem()
            }
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
            currentHelperState: { [helper] in helper.installationState },
            onInstallHelper: { [weak self] in
                guard let self else { return }
                self.apply(self.config)
            },
            onRemoveHelper: { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    // Put the machine back before removing the only thing that
                    // can put it back.
                    if self.config != .off {
                        try? await self.helper.apply(.off)
                        self.config = .off
                        self.menuController.show(.off)
                    }
                    try? await self.helper.uninstall()
                }
            }
        )
        let controller = SettingsWindowController(rootView: view)
        settingsWindow = controller
        controller.present()
    }
}
