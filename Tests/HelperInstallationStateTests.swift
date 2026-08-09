import ServiceManagement
import XCTest

/// `SMAppService.status` is a hint, not proof — it lies in both directions:
/// it keeps saying `.enabled` after the launchd job is gone, and it says
/// `.notFound` for a daemon that is registered, running and answering, which is
/// what `sfltool resetbtm` leaves behind.
///
/// Neither signal alone is trustworthy, so the state the user is shown is
/// resolved from both.
final class HelperInstallationStateTests: XCTestCase {
    private func state(reachable: Bool, _ status: SMAppService.Status) -> HelperInstallationState {
        HelperInstallationState.resolve(reachable: reachable, status: status)
    }

    // MARK: - Working

    func testAnsweringAndRegisteredIsInstalled() {
        XCTAssertEqual(state(reachable: true, .enabled), .installed)
    }

    // MARK: - Answering without a registration

    /// What `sfltool resetbtm` produces: the job keeps running, its approval
    /// record is gone. It works now and will not survive a reboot, and nothing
    /// re-registers it on its own, because the app only registers a helper that
    /// is *not* answering.
    func testAnsweringWithNoRegistrationRecordIsOrphaned() {
        XCTAssertEqual(state(reachable: true, .notFound), .orphaned)
    }

    func testAnsweringWhileUnregisteredIsOrphaned() {
        XCTAssertEqual(state(reachable: true, .notRegistered), .orphaned)
    }

    // MARK: - Not answering

    func testNotAnsweringAndAwaitingApprovalAsksForApproval() {
        XCTAssertEqual(state(reachable: false, .requiresApproval), .requiresApproval)
    }

    /// A record that exists while nothing answers is broken, not absent — the
    /// job is registered and cannot start. Two known causes, same repair: a
    /// stale record that outlived its job, and a record whose bookmark still
    /// points at an app bundle that was replaced by an update.
    ///
    /// Worth distinguishing from `.notInstalled` because the app may fix this
    /// one on its own: the user already approved this helper once.
    func testNotAnsweringDespiteAnEnabledRecordIsBroken() {
        XCTAssertEqual(state(reachable: false, .enabled), .broken)
    }

    func testNotAnsweringWithNoRecordIsNotInstalled() {
        XCTAssertEqual(state(reachable: false, .notFound), .notInstalled)
    }
}
