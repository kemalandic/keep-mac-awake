import SwiftUI

struct SettingsView: View {
    private let preferences: Preferences
    private let currentHelperState: () async -> HelperInstallationState
    private let onInstallHelper: () async -> Void
    private let onRemoveHelper: () async -> Void

    @State private var launchAtLogin: Bool
    /// Nil until the first reading comes back. The helper state cannot be read
    /// synchronously any more — it asks the daemon, not just its record — and
    /// guessing while the answer is in flight is what showed "Helper not
    /// installed" for a helper that was working.
    @State private var helperState: HelperInstallationState?
    @State private var busy = false
    @State private var errorMessage: String?

    init(preferences: Preferences,
         currentHelperState: @escaping () async -> HelperInstallationState,
         onInstallHelper: @escaping () async -> Void,
         onRemoveHelper: @escaping () async -> Void) {
        self.preferences = preferences
        self.currentHelperState = currentHelperState
        self.onInstallHelper = onInstallHelper
        self.onRemoveHelper = onRemoveHelper
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

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .task { await refreshHelperState() }
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
            await refreshHelperState()
            busy = false
        }
    }

    private func refreshHelperState() async {
        helperState = await currentHelperState()
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
