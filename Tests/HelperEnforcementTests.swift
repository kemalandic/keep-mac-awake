import XCTest

/// The helper is the rule setter. It has to survive the app quitting and a
/// reboot, so what the user asked for is written down rather than held in
/// memory, and re-asserted whenever the machine drifts away from it.
final class HelperEnforcementTests: XCTestCase {
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

    private let keepAwakeOnly = PowerConfig(keepAwake: true,
                                            keepDisplayOn: false,
                                            stayAwakeWithLidClosed: false)

    // MARK: - Remembering the rule

    func testRemembersWhatTheUserAskedForSoItCanBeEnforcedLater() {
        apply(keepAwakeOnly)

        XCTAssertEqual(desired.load(), keepAwakeOnly)
    }

    func testForgetsTheRuleWhenEverythingIsSwitchedOff() {
        apply(keepAwakeOnly)
        apply(.off)

        XCTAssertNil(desired.load(), "with nothing switched on the app claims nothing")
    }

    // MARK: - Enforcing it

    func testRewritesASettingAnotherWriterChanged() {
        apply(keepAwakeOnly)
        control.settings.sleepMinutes = 20  // someone else ran pmset

        service.enforce()

        XCTAssertEqual(control.settings.sleepMinutes, 0, "our switch must win")
    }

    func testEnforcingSurvivesAHelperRestart() {
        apply(keepAwakeOnly)
        control.settings.sleepMinutes = 20

        // The rule lives on disk, so a fresh helper enforces it just the same.
        let restarted = HelperService(control: control,
                                      store: baseline,
                                      desired: desired,
                                      pause: { _ in })
        restarted.enforce()

        XCTAssertEqual(control.settings.sleepMinutes, 0)
    }

    func testEnforcingLeavesSettingsTheUserDidNotSwitchOnAlone() {
        apply(keepAwakeOnly)
        control.settings.displaySleepMinutes = 15

        service.enforce()

        XCTAssertEqual(control.settings.displaySleepMinutes, 15,
                       "the display timeout is the user's while the switch is off")
    }

    func testEnforcingWritesNothingWhenTheMachineAlreadyObeys() {
        apply(keepAwakeOnly)
        let writesAfterApply = control.writes.count

        service.enforce()

        XCTAssertEqual(control.writes.count, writesAfterApply,
                       "an obedient machine must not be written to")
    }

    // MARK: - Upgrading from a version that only wrote settings

    /// Those versions recorded a baseline but no rule, so a machine whose
    /// switches are on arrives here with nothing to enforce. The baseline is
    /// the marker that this app owns the machine's settings: where it exists
    /// and no rule does, what is in effect *is* the rule.
    func testAdoptsTheSettingsAlreadyInEffectAsTheRule() {
        apply(keepAwakeOnly)
        desired.clear()  // as an upgrade from a version that never wrote one

        service.adoptSettingsInEffectAsRule()

        XCTAssertEqual(desired.load(), keepAwakeOnly)
    }

    func testAdoptedRuleIsThenEnforced() {
        apply(keepAwakeOnly)
        desired.clear()
        service.adoptSettingsInEffectAsRule()

        control.settings.sleepMinutes = 20
        service.enforce()

        XCTAssertEqual(control.settings.sleepMinutes, 0)
    }

    func testClaimsNothingOnAMachineThisAppDoesNotOwn() {
        control.settings = PowerSettings(sleepMinutes: 0, displaySleepMinutes: 0, disableSleep: true)

        service.adoptSettingsInEffectAsRule()

        XCTAssertNil(desired.load(),
                     "without a baseline the app never touched this machine — those values are not ours")
    }

    func testLeavesAnExistingRuleAlone() {
        apply(keepAwakeOnly)
        control.settings.displaySleepMinutes = 0  // changed by someone else

        service.adoptSettingsInEffectAsRule()

        XCTAssertEqual(desired.load(), keepAwakeOnly,
                       "a recorded rule is not re-derived from whatever is in effect")
    }

    func testDoesNotRecordARuleThatClaimsNothing() {
        apply(keepAwakeOnly)
        apply(.off)  // releases the baseline

        service.adoptSettingsInEffectAsRule()

        XCTAssertNil(desired.load())
    }

    func testEnforcingDoesNothingWhenNothingWasEverAskedFor() {
        control.settings.sleepMinutes = 20

        service.enforce()

        XCTAssertEqual(control.settings.sleepMinutes, 20,
                       "the helper must not impose settings the user never chose")
    }
}
