import Foundation
import ServiceManagement

/// The part of `SMAppService` this app drives, behind a protocol so the
/// registration dance can be tested without a real launchd.
protocol HelperRegistering {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
}

extension SMAppService: HelperRegistering {}

/// Replaces an existing registration with a fresh one.
///
/// The order matters more than it looks. `unregister()` returns before the
/// record is actually gone, so registering straight afterwards re-uses the old
/// Background Task Management entry — including its bookmark to the app bundle.
/// Replace the bundle (any update: drag from the DMG, choose Replace) and that
/// bookmark no longer resolves, so launchd cannot find the daemon's binary and
/// the job dies with EX_CONFIG on every attempt, forever.
///
/// The record's identity is the tell: a registration that was really removed
/// comes back with a new one.
enum HelperReregistration {
    /// How many times to look for the old record to disappear before giving up
    /// on waiting. Registering on top of a stubborn record is still better than
    /// leaving the machine with no helper at all.
    private static let removalPolls = 10
    private static let registerAttempts = 5

    static func run(on service: HelperRegistering,
                    pause: (Int) async -> Void) async throws {
        do {
            try await service.unregister()
        } catch {
            // Not a reason to stop: the record may already be gone, or gone in
            // a way that reports failure. Registering is what matters.
            Log.helper.notice("unregister reported \(error.localizedDescription, privacy: .public)")
        }

        for poll in 1...removalPolls {
            guard service.status == .enabled else { break }
            await pause(poll)
        }

        if service.status == .enabled {
            Log.helper.notice("old registration did not clear — registering over it")
        }

        try await HelperRegistration.attempt(times: registerAttempts, pause: pause) {
            try service.register()
        }
    }
}
