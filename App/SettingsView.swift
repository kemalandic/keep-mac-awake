import AppKit
import SwiftUI

struct SettingsView: View {
    private let preferences: Preferences
    private let currentHelperState: () async -> HelperInstallationState
    private let onInstallHelper: () async -> Void
    private let onRemoveHelper: () async -> Void
    private let onRestoreDefaults: () async -> Void
    private let currentBlockers: () async -> [SleepBlocker]?

    @State private var launchAtLogin: Bool
    /// Nil until the first reading comes back. The helper state cannot be read
    /// synchronously any more — it asks the daemon, not just its record — and
    /// guessing while the answer is in flight is what showed "Helper not
    /// installed" for a helper that was working.
    @State private var helperState: HelperInstallationState?
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var blockers: [SleepBlockerSummary] = []
    @State private var confirmRestore = false

    init(preferences: Preferences,
         currentHelperState: @escaping () async -> HelperInstallationState,
         currentBlockers: @escaping () async -> [SleepBlocker]?,
         onInstallHelper: @escaping () async -> Void,
         onRemoveHelper: @escaping () async -> Void,
         onRestoreDefaults: @escaping () async -> Void) {
        self.preferences = preferences
        self.currentHelperState = currentHelperState
        self.currentBlockers = currentBlockers
        self.onInstallHelper = onInstallHelper
        self.onRemoveHelper = onRemoveHelper
        self.onRestoreDefaults = onRestoreDefaults
        _launchAtLogin = State(initialValue: LoginItem.isEnabled)
    }

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in
                        do {
                            try LoginItem.setEnabled(value)
                            preferences.launchAtLogin = value
                        } catch {
                            launchAtLogin = !value
                            errorMessage = error.localizedDescription
                        }
                    }
                Text("Your power settings stay in effect whether or not this app "
                     + "is running — launching at login only puts the menu back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Helper") {
                HStack {
                    Text(helperStatusText)
                    Spacer()
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        actionButton
                    }
                }
                Text(helperExplanation)
                    .font(.caption)
                    .foregroundStyle(needsAttention ? .orange : .secondary)
            }

            if !blockers.isEmpty {
                Section("Keeping this Mac awake") {
                    ForEach(blockers, id: \.self) { blocker in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(blocker.name)
                            Text("\(blocker.headline) — \(blocker.detail)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("These override the power settings while they last. If "
                         + "your Mac stays awake with every switch off, this is why.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Power settings") {
                HStack {
                    Text("Hand the settings back to macOS")
                    Spacer()
                    Button("Restore Defaults…") { confirmRestore = true }
                }
                Text("Puts every power setting back to its macOS default and "
                     + "releases this app's records. Use it if switching "
                     + "everything off did not give you your Mac back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Restore macOS power defaults?",
                            isPresented: $confirmRestore) {
            Button("Restore Defaults", role: .destructive) { run(onRestoreDefaults) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every power setting goes back to its macOS default, including "
                 + "ones you changed yourself outside this app. This cannot be undone.")
        }
        .task { await refreshEverything() }
        // Coming back to an already-open window is a moment where the user is
        // looking at this again, and what is holding the Mac awake changes on
        // its own. Cheaper and more honest than a timer that would keep running
        // whether anyone was reading it or not.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await refreshEverything() }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch helperState {
        case .installed:
            Button("Remove") { run(onRemoveHelper) }
        case .requiresApproval:
            Button("Open Settings") { run(onInstallHelper) }
        case .orphaned, .broken:
            Button("Repair…") { run(onInstallHelper) }
        case .notInstalled:
            Button("Install…") { run(onInstallHelper) }
        case nil:
            EmptyView()
        }
    }

    private func run(_ action: @escaping () async -> Void) {
        Task { @MainActor in
            busy = true
            await action()
            await refreshEverything()
            busy = false
        }
    }

    private func refreshEverything() async {
        await refreshHelperState()
        await refreshBlockers()
    }

    private func refreshHelperState() async {
        helperState = await currentHelperState()
    }

    /// Nil means we could not ask, which is not the same as "nothing is holding
    /// the Mac awake" — keep whatever was last known rather than claiming all clear.
    private func refreshBlockers() async {
        if let latest = await currentBlockers() { blockers = SleepBlocker.summarised(latest) }
    }

    private var needsAttention: Bool {
        helperState == .orphaned || helperState == .broken
    }

    private var helperStatusText: String {
        switch helperState {
        case .installed: return "Helper installed"
        case .requiresApproval: return "Waiting for your approval"
        case .orphaned: return "Helper running but not registered"
        case .broken: return "Helper registered but not starting"
        case .notInstalled: return "Helper not installed"
        case nil: return "Checking…"
        }
    }

    private var helperExplanation: String {
        switch helperState {
        case .orphaned:
            // The state `sfltool resetbtm` leaves behind. It works until the
            // next reboot, and the app cannot fix it without being told to.
            return "The helper is answering, but macOS has no record of it — it "
                + "will not come back after a restart. Repair re-registers it."
        case .broken:
            return "macOS has a registration for the helper but cannot start it. "
                + "Repair replaces the registration."
        default:
            return "Changing power settings needs administrator rights, so the "
                + "app installs a small helper once. Removing it puts your "
                + "original settings back first."
        }
    }
}
