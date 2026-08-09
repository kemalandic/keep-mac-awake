import XCTest

/// Registering right after an unregister fails with "Operation not permitted"
/// until launchd has finished tearing the old job down. Giving up on the first
/// attempt is what leaves the machine with no helper at all — unregistered, yet
/// still answering from the old process, which the app cannot heal by itself.
final class HelperRegistrationTests: XCTestCase {
    private struct Denied: Error, Equatable {
        let attempt: Int
    }

    func testRegistersOnceWhenTheFirstAttemptSucceeds() async throws {
        var attempts = 0

        try await HelperRegistration.attempt(times: 3, pause: { _ in }) {
            attempts += 1
        }

        XCTAssertEqual(attempts, 1)
    }

    func testKeepsTryingWhileLaunchdIsStillLettingGo() async throws {
        var attempts = 0

        try await HelperRegistration.attempt(times: 5, pause: { _ in }) {
            attempts += 1
            if attempts < 3 { throw Denied(attempt: attempts) }
        }

        XCTAssertEqual(attempts, 3, "the attempt that would have succeeded must be reached")
    }

    func testGivesUpAfterTheAllowedAttemptsAndReportsTheLastFailure() async {
        var attempts = 0

        do {
            try await HelperRegistration.attempt(times: 3, pause: { _ in }) {
                attempts += 1
                throw Denied(attempt: attempts)
            }
            XCTFail("a registration that never succeeds must be reported")
        } catch {
            XCTAssertEqual(error as? Denied, Denied(attempt: 3),
                           "the caller needs the reason, not a generic failure")
        }

        XCTAssertEqual(attempts, 3)
    }

    func testWaitsBetweenAttemptsButNotAfterTheLastOne() async {
        var pauses = 0

        try? await HelperRegistration.attempt(times: 3, pause: { _ in pauses += 1 }) {
            throw Denied(attempt: 0)
        }

        XCTAssertEqual(pauses, 2, "three attempts have two gaps between them")
    }
}
