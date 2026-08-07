import Foundation
import ServiceManagement

enum HelperInstallationState: Equatable {
    case notInstalled
    case requiresApproval
    case installed
}

enum PowerHelperError: LocalizedError {
    case needsApproval
    case connectionFailed
    case helperReported(String)

    var errorDescription: String? {
        switch self {
        case .needsApproval:
            return "The helper is waiting for your approval."
        case .connectionFailed:
            return "Could not reach the helper."
        case .helperReported(let message):
            return message
        }
    }
}

/// App-side gateway to the privileged helper.
final class PowerHelperClient {
    private let service = SMAppService.daemon(plistName: HelperConstants.plistName)
    private var connection: NSXPCConnection?

    var installationState: HelperInstallationState {
        switch service.status {
        case .enabled: return .installed
        case .requiresApproval: return .requiresApproval
        default: return .notInstalled
        }
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

        Log.helper.notice("helper not answering (status=\(String(describing: self.installationState), privacy: .public)) — registering")
        dropConnection()

        do {
            try service.register()
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

    /// Replaces a running helper after the app bundle is updated in place.
    /// launchd keeps the old daemon alive across an app replacement, so without
    /// this the machine keeps running the previous version's code.
    ///
    /// Safe at any time: the helper never reverts settings, so restarting it
    /// cannot disturb what is already applied.
    func reregister() async throws {
        Log.helper.notice("re-registering helper")
        dropConnection()
        try? await service.unregister()
        try service.register()

        for _ in 0..<10 {
            if await isReachable() { return }
            try? await Task.sleep(for: .milliseconds(400))
        }
        throw PowerHelperError.connectionFailed
    }

    func isReachable() async -> Bool {
        await helperVersion() != nil
    }

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

/// Runs its body at most once. Both the XPC reply block and the connection's
/// error handler can fire; resuming a continuation twice would crash, and never
/// resuming it would hang the caller forever.
private final class Once {
    private var done = false
    private let lock = NSLock()

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
