import XCTest

/// The escape hatch from a trap this app can set for itself.
///
/// The baseline is captured from whatever the machine happens to have the first
/// time a switch is flipped. If something had already set `displaysleep 0` —
/// another utility, an earlier version of this app, the user's own pmset — then
/// "the machine's own value" is recorded as "never sleep". Switching everything
/// off faithfully restores that, and then releases the baseline: the display
/// stays on forever and there is no longer anything in the app to undo it.
///
/// Restoring macOS defaults is the way out, and it has to release both records
/// — otherwise the app still believes it owns settings it just gave up.
final class HelperRestoreDefaultsTests: XCTestCase {
    private var control: FakePowerControl!
    private var directory: URL!
    private var baseline: BaselineStore!
    private var desired: DesiredStore!
    private var service: HelperService!

    override func setUp() {
        super.setUp()
        control = FakePowerControl()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kma-\(UUID().uuidString)")
        baseline = BaselineStore(url: directory.appendingPathComponent("baseline.plist"))
        desired = DesiredStore(url: directory.appendingPathComponent("desired.plist"))
        service = HelperService(control: control,
                                store: baseline,
                                desired: desired,
                                pause: { _ in })
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    @discardableResult
    private func apply(_ config: PowerConfig) -> (ok: Bool, message: String?) {
        let data = try! PropertyListEncoder().encode(config)
        var result: (Bool, String?) = (false, "no reply")
        let done = expectation(description: "reply")
        service.apply(data) { ok, message in
            result = (ok, message)
            done.fulfill()
        }
        wait(for: [done], timeout: 1)
        return result
    }

    @discardableResult
    private func restoreDefaults() -> (ok: Bool, message: String?) {
        var result: (Bool, String?) = (false, "no reply")
        let done = expectation(description: "reply")
        service.restoreDefaults { ok, message in
            result = (ok, message)
            done.fulfill()
        }
        wait(for: [done], timeout: 1)
        return result
    }

    private let keepDisplayOn = PowerConfig(keepAwake: false,
                                            keepDisplayOn: true,
                                            stayAwakeWithLidClosed: false)

    // MARK: - The way out

    func testHandsThePowerSettingsBackToMacOS() {
        apply(keepDisplayOn)

        let result = restoreDefaults()

        XCTAssertTrue(result.ok)
        XCTAssertEqual(control.restoreDefaultsCalls, 1)
    }

    func testReleasesBothRecordsSoTheAppNoLongerClaimsTheMachine() {
        apply(keepDisplayOn)
        XCTAssertTrue(baseline.exists, "precondition: the app owns the settings")

        restoreDefaults()

        XCTAssertFalse(baseline.exists, "a baseline we have given up on is a lie")
        XCTAssertNil(desired.load(), "enforcing a rule we just abandoned would undo the restore")
    }

    /// The point of the whole feature: a poisoned baseline must not survive it.
    func testAPoisonedBaselineDoesNotSurvive() {
        // The machine already had "never sleep the display" before we touched it.
        control.settings = PowerSettings(sleepMinutes: 10, displaySleepMinutes: 0, disableSleep: false)
        apply(keepDisplayOn)
        XCTAssertEqual(baseline.load()?.displaySleepMinutes, 0, "precondition: the baseline is poisoned")

        restoreDefaults()

        XCTAssertFalse(baseline.exists)
        XCTAssertEqual(control.restoreDefaultsCalls, 1)
    }

    func testNothingIsEnforcedAfterwards() {
        apply(keepDisplayOn)
        restoreDefaults()

        control.settings.displaySleepMinutes = 15
        service.enforce()

        XCTAssertEqual(control.settings.displaySleepMinutes, 15,
                       "the app gave up ownership — it must not pull the settings back")
    }

    /// `pmset restoredefaults` restores the per-profile settings and leaves the
    /// system-wide lid override exactly as it was. A user who had used the
    /// lid switch would be told their Mac was handed back while it still
    /// refused to sleep with the lid closed — the promise half kept.
    func testTheLidOverrideIsClearedTooEvenThoughRestoringDefaultsLeavesIt() {
        control.restoreDefaultsLeavesDisableSleep = true
        apply(PowerConfig(keepAwake: false, keepDisplayOn: false, stayAwakeWithLidClosed: true))
        XCTAssertTrue(control.settings.disableSleep, "precondition: the lid override is on")

        let result = restoreDefaults()

        XCTAssertTrue(result.ok)
        XCTAssertFalse(control.settings.disableSleep,
                       "handing the settings back has to include this one")
    }

    // MARK: - Failure

    func testKeepsTheRecordsWhenTheRestoreItselfFails() {
        apply(keepDisplayOn)
        control.restoreDefaultsError = PmsetControl.Failure.nonZeroExit(1, "boom")

        let result = restoreDefaults()

        XCTAssertFalse(result.ok)
        XCTAssertNotNil(result.message)
        XCTAssertTrue(baseline.exists,
                      "dropping the records after a failed restore would strand the user for good")
        XCTAssertNotNil(desired.load())
    }
}
