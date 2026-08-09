import Foundation
import ServiceManagement

enum HelperInstallationState: Equatable {
    case notInstalled
    case requiresApproval
    case installed
    /// The daemon answers but macOS holds no registration for it. It works
    /// right now and will not survive a reboot, and the app cannot heal it by
    /// itself: registration only happens for a helper that is *not* answering.
    case orphaned
    /// Registered and not answering: the job exists and cannot start. Two known
    /// causes, same repair — a record that outlived its job, and a record whose
    /// bookmark still points at an app bundle that an update replaced.
    case broken

    /// Resolved from both signals because neither is trustworthy alone.
    ///
    /// `SMAppService.status` lies in both directions — `.enabled` for a job
    /// that is gone, `.notFound` for one that is registered and answering, the
    /// state `sfltool resetbtm` leaves behind. Reachability proves the daemon
    /// works; only the status can say whether it will still be there tomorrow.
    static func resolve(reachable: Bool, status: SMAppService.Status) -> HelperInstallationState {
        if reachable {
            return status == .enabled ? .installed : .orphaned
        }
        switch status {
        case .requiresApproval: return .requiresApproval
        case .enabled: return .broken
        default: return .notInstalled
        }
    }
}

enum PowerHelperError: LocalizedError {
    case needsApproval
    case connectionFailed
    case registrationFailed(String)
    case helperReported(String)

    var errorDescription: String? {
        switch self {
        case .needsApproval:
            return "The helper is waiting for your approval."
        case .connectionFailed:
            return "Could not reach the helper."
        case .registrationFailed(let message):
            return "macOS refused to register the helper: \(message)"
        case .helperReported(let message):
            return message
        }
    }
}

/// App-side gateway to the privileged helper.
final class PowerHelperClient {
    private let service = SMAppService.daemon(plistName: HelperConstants.plistName)
    private var connection: NSXPCConnection?

    /// Asks the daemon, not just the record. `SMAppService.status` alone is what
    /// made the Settings window report "not installed" for a helper that was
    /// registered, running and answering.
    func installationState() async -> HelperInstallationState {
        HelperInstallationState.resolve(reachable: await isReachable(), status: service.status)
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Makes sure a helper is actually answering before we rely on it.
    ///
    /// SMAppService.status is a hint, not proof: a stale Background Task
    /// Management record keeps reporting .enabled long after the launchd job is
    /// gone, even across app deletion. Reachability is the only real test.
    func prepareHelper() async throws {
        if await isReachable() { return }

        Log.helper.notice("helper not answering (status=\(String(describing: self.service.status), privacy: .public)) — registering")
        dropConnection()

        do {
            try await HelperRegistration.attempt(times: 3, pause: Self.backOff) {
                try service.register()
            }
        } catch {
            // Already-registered is not a failure: the record exists, the job
            // just is not answering yet (typically awaiting approval).
            Log.helper.notice("register returned \(error.localizedDescription, privacy: .public) — continuing to probe")
        }

        for _ in 0..<10 {
            if await isReachable() {
                Log.helper.notice("helper answering after registration")
                return
            }
            try? await Task.sleep(for: .milliseconds(400))
        }

        throw PowerHelperError.needsApproval
    }

    func uninstall() async throws {
        Log.helper.notice("unregistering helper daemon")
        dropConnection()
        try await service.unregister()
    }

    /// Replaces a running helper after the app bundle is updated in place, and
    /// repairs a registration that went missing under a running daemon.
    /// launchd keeps the old daemon alive across an app replacement, so without
    /// this the machine keeps running the previous version's code.
    ///
    /// Safe at any time: the helper never reverts settings, so restarting it
    /// cannot disturb what is already applied.
    ///
    /// The window between unregister and register is the dangerous part — a
    /// failure there leaves the machine with no registration at all — so the
    /// registration is retried rather than attempted once.
    func reregister() async throws {
        Log.helper.notice("re-registering helper")
        dropConnection()

        do {
            try await HelperReregistration.run(on: service, pause: Self.backOff)
        } catch {
            Log.helper.error("""
            re-registration failed: \(error.localizedDescription, privacy: .public) \
            — the machine may now have no registered helper
            """)
            throw PowerHelperError.registrationFailed(error.localizedDescription)
        }

        for _ in 0..<10 {
            if await isReachable() { return }
            try? await Task.sleep(for: .milliseconds(400))
        }
        throw PowerHelperError.connectionFailed
    }

    /// launchd needs a moment to let go of a job before the same service can be
    /// submitted again; the first retry is usually still too early.
    private static func backOff(_ attempt: Int) async {
        try? await Task.sleep(for: .milliseconds(500 * attempt))
    }

    /// Whether the helper actually answers, within a bounded wait.
    ///
    /// The bound is the point. A daemon launchd cannot start leaves the XPC
    /// message queued with no reply and no error, so an unbounded probe hangs
    /// the app on launch — no menu state, no error, nothing in the log.
    func isReachable() async -> Bool {
        let answered = await Deadline.run(within: Self.probeTimeout) { [self] in
            await helperVersion()
        }

        guard let answered else {
            // A wedged connection stays wedged; the next probe needs a new one.
            Log.helper.notice("helper did not answer within \(Self.probeTimeout, privacy: .public)s")
            dropConnection()
            return false
        }
        return answered != nil
    }

    /// Long enough for a healthy daemon that has to be launched on demand,
    /// short enough that a broken one does not stall the app.
    private static let probeTimeout: Double = 5

    func apply(_ config: PowerConfig) async throws {
        let data = try PropertyListEncoder().encode(config)
        let connection = try openConnection()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                Log.helper.error("xpc failed: \(error.localizedDescription, privacy: .public)")
                once.run { continuation.resume(throwing: PowerHelperError.connectionFailed) }
            }) as? PowerHelperProtocol else {
                once.run { continuation.resume(throwing: PowerHelperError.connectionFailed) }
                return
            }

            proxy.apply(data) { ok, message in
                once.run {
                    if ok {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: PowerHelperError.helperReported(
                            message ?? "The helper could not change the settings."))
                    }
                }
            }
        }
    }

    /// What the machine actually has right now — the menu shows this, not a
    /// remembered value, so it stays honest across reboots and manual pmset use.
    func currentConfig() async -> PowerConfig? {
        guard let connection = try? openConnection() else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<PowerConfig?, Never>) in
            let once = Once()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                once.run { continuation.resume(returning: nil) }
            }) as? PowerHelperProtocol else {
                once.run { continuation.resume(returning: nil) }
                return
            }
            proxy.currentConfig { data in
                let config = data.flatMap { try? PropertyListDecoder().decode(PowerConfig.self, from: $0) }
                once.run { continuation.resume(returning: config) }
            }
        }
    }

    func helperVersion() async -> String? {
        guard let connection = try? openConnection() else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let once = Once()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                once.run { continuation.resume(returning: nil) }
            }) as? PowerHelperProtocol else {
                once.run { continuation.resume(returning: nil) }
                return
            }
            proxy.helperVersion { version in
                once.run { continuation.resume(returning: version) }
            }
        }
    }

    /// Tears down our own connection. Nothing reacts to this — a dropped
    /// connection is not an event worth telling the user about.
    private func dropConnection() {
        let old = connection
        connection = nil
        old?.invalidate()
    }

    private func openConnection() throws -> NSXPCConnection {
        if connection == nil {
            let newConnection = NSXPCConnection(
                machServiceName: HelperConstants.machServiceName,
                options: .privileged
            )
            newConnection.remoteObjectInterface = NSXPCInterface(with: PowerHelperProtocol.self)
            newConnection.invalidationHandler = { [weak self, weak newConnection] in
                DispatchQueue.main.async {
                    guard let self, let newConnection,
                          self.connection === newConnection else { return }
                    self.connection = nil
                }
            }
            newConnection.interruptionHandler = { [weak self] in
                DispatchQueue.main.async { self?.connection = nil }
            }
            newConnection.resume()
            connection = newConnection
        }

        guard let connection else { throw PowerHelperError.connectionFailed }
        return connection
    }
}

