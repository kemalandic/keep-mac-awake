import ServiceManagement
import XCTest

/// Registering again before the old registration has actually gone leaves the
/// previous record in place — same Background Task Management entry, still
/// bookmarked to the app bundle that was just replaced. launchd then cannot
/// resolve the daemon's path and the job dies with EX_CONFIG on every attempt.
///
/// The tell is the record's identity: a registration that was really removed
/// comes back with a new one.
final class HelperReregistrationTests: XCTestCase {
    private final class FakeService: HelperRegistering {
        /// Readings handed out in order, the last one repeating.
        var statuses: [SMAppService.Status] = [.notFound]
        private var reads = 0

        var status: SMAppService.Status {
            defer { reads += 1 }
            return statuses[min(reads, statuses.count - 1)]
        }

        var unregisterError: Error?
        var registerErrors: [Error] = []

        private(set) var unregisterCalls = 0
        private(set) var statusesWhenRegistered: [SMAppService.Status] = []

        func register() throws {
            statusesWhenRegistered.append(statuses[min(reads, statuses.count - 1)])
            if !registerErrors.isEmpty { throw registerErrors.removeFirst() }
        }

        func unregister() async throws {
            unregisterCalls += 1
            if let unregisterError { throw unregisterError }
        }
    }

    private struct Denied: Error {}

    /// launchd will not let go of a registration whose job is still running.
    /// Replacing the app bundle while the old daemon is alive therefore keeps
    /// the old record — and its bookmark to a bundle that no longer exists.
    /// Stopping the daemon first is what makes the removal land.
    func testStopsTheRunningDaemonBeforeTouchingTheRegistration() async throws {
        let service = FakeService()
        service.statuses = [.enabled, .notFound]
        var order: [String] = []

        try await HelperReregistration.run(
            on: service,
            stopRunning: { order.append("stop") },
            pause: { _ in }
        )

        service.unregisterCalls > 0 ? order.append("unregister") : ()
        XCTAssertEqual(order.first, "stop", "unregistering a live job leaves the record in place")
        XCTAssertEqual(service.unregisterCalls, 1)
    }

    /// A daemon that will not stop is not a reason to give up: the register
    /// still has a chance, and leaving no helper at all is worse.
    func testCarriesOnWhenTheDaemonWillNotStop() async throws {
        let service = FakeService()
        service.statuses = [.notFound]

        try await HelperReregistration.run(
            on: service,
            stopRunning: { throw Denied() },
            pause: { _ in }
        )

        XCTAssertEqual(service.statusesWhenRegistered.count, 1)
    }

    func testRemovesTheOldRegistrationBeforeCreatingANewOne() async throws {
        let service = FakeService()
        service.statuses = [.enabled, .notFound]

        try await HelperReregistration.run(on: service, pause: { _ in })

        XCTAssertEqual(service.unregisterCalls, 1)
        XCTAssertEqual(service.statusesWhenRegistered, [.notFound],
                       "registering while the old record is still there reuses it")
    }

    func testWaitsForTheRemovalToLandRatherThanAssumingItWasImmediate() async throws {
        let service = FakeService()
        service.statuses = [.enabled, .enabled, .enabled, .notFound]

        try await HelperReregistration.run(on: service, pause: { _ in })

        XCTAssertEqual(service.statusesWhenRegistered, [.notFound])
    }

    func testRegistersAnywayWhenTheOldRecordRefusesToGo() async throws {
        let service = FakeService()
        service.statuses = [.enabled]  // never clears

        try await HelperReregistration.run(on: service, pause: { _ in })

        XCTAssertEqual(service.statusesWhenRegistered, [.enabled],
                       "giving up entirely would leave no helper at all")
    }

    func testStillRegistersWhenRemovalItselfFails() async throws {
        let service = FakeService()
        service.statuses = [.notFound]
        service.unregisterError = Denied()

        try await HelperReregistration.run(on: service, pause: { _ in })

        XCTAssertEqual(service.statusesWhenRegistered.count, 1,
                       "an unregister that throws is not a reason to skip registering")
    }

    func testRetriesRegistrationWhileLaunchdIsStillLettingGo() async throws {
        let service = FakeService()
        service.statuses = [.notFound]
        service.registerErrors = [Denied(), Denied()]

        try await HelperReregistration.run(on: service, pause: { _ in })

        XCTAssertEqual(service.statusesWhenRegistered.count, 3)
    }

    func testReportsAFailureThatNeverClears() async {
        let service = FakeService()
        service.statuses = [.notFound]
        service.registerErrors = Array(repeating: Denied(), count: 99)

        do {
            try await HelperReregistration.run(on: service, pause: { _ in })
            XCTFail("a registration that never succeeds must be reported")
        } catch {
            XCTAssertTrue(error is Denied)
        }
    }
}
