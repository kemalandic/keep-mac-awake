import SwiftUI

struct SettingsView: View {
    private let preferences: Preferences
    private let currentHelperState: () -> HelperInstallationState
    private let onInstallHelper: () -> Void
    private let onRemoveHelper: () -> Void

    @State private var launchAtLogin: Bool
    @State private var helperState: HelperInstallationState
    @State private var errorMessage: String?

    init(preferences: Preferences,
         currentHelperState: @escaping () -> HelperInstallationState,
         onInstallHelper: @escaping () -> Void,
         onRemoveHelper: @escaping () -> Void) {
        self.preferences = preferences
        self.currentHelperState = currentHelperState
        self.onInstallHelper = onInstallHelper
        self.onRemoveHelper = onRemoveHelper
        _launchAtLogin = State(initialValue: LoginItem.isEnabled)
        _helperState = State(initialValue: currentHelperState())
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
                    switch helperState {
                    case .installed:
                        Button("Remove") {
                            onRemoveHelper()
                            refreshHelperState()
                        }
                    case .requiresApproval:
                        Button("Open Settings") {
                            onInstallHelper()
                            refreshHelperState()
                        }
                    case .notInstalled:
                        Button("Install…") {
                            onInstallHelper()
                            refreshHelperState()
                        }
                    }
                }
                Text("Changing power settings needs administrator rights, so the "
                     + "app installs a small helper once. Removing it puts your "
                     + "original settings back first.")
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
    }

    /// Install and remove finish asynchronously, so poll briefly rather than
    /// reading once and showing a stale label.
    private func refreshHelperState() {
        helperState = currentHelperState()
        Task { @MainActor in
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(300))
                let latest = currentHelperState()
                if latest != helperState {
                    helperState = latest
                    return
                }
            }
        }
    }

    private var helperStatusText: String {
        switch helperState {
        case .installed: return "Helper installed"
        case .requiresApproval: return "Waiting for your approval"
        case .notInstalled: return "Helper not installed"
        }
    }
}
