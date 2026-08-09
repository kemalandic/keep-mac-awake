import Foundation

/// Registering a daemon is not reliably immediate.
///
/// `SMAppService.register()` fails with "Operation not permitted" for a few
/// seconds after the same service was unregistered — launchd has not finished
/// letting go of the old job. One attempt is not enough: giving up there leaves
/// the machine unregistered while the previous daemon keeps answering, and the
/// app cannot recover from that on its own, because it only ever registers a
/// helper that is *not* answering.
enum HelperRegistration {
    /// Runs `register` until it succeeds or the allowance runs out, rethrowing
    /// the last failure so the caller can say what actually went wrong.
    static func attempt(times: Int,
                        pause: (Int) async -> Void,
                        register: () throws -> Void) async throws {
        var lastFailure: Error?

        for attempt in 1...max(times, 1) {
            do {
                try register()
                return
            } catch {
                lastFailure = error
                if attempt < times { await pause(attempt) }
            }
        }

        if let lastFailure { throw lastFailure }
    }
}
