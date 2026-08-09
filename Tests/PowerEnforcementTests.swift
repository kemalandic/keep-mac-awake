import XCTest

/// The rule this app now claims: while a switch is on, the machine keeps that
/// value no matter who else writes it. What it deliberately does *not* claim:
/// authority over settings the user never switched on.
final class PowerEnforcementTests: XCTestCase {
    private let allOn = PowerConfig(keepAwake: true,
                                    keepDisplayOn: true,
                                    stayAwakeWithLidClosed: true)

    // MARK: - Nothing to do

    func testNoCorrectionWhenEveryActiveSwitchIsAlreadyInEffect() {
        let current = PowerSettings(sleepMinutes: 0, displaySleepMinutes: 0, disableSleep: true)

        XCTAssertNil(PowerEnforcement.correction(for: allOn, given: current))
    }

    func testNothingIsEnforcedWhileEverySwitchIsOff() {
        let current = PowerSettings(sleepMinutes: 10, displaySleepMinutes: 5, disableSleep: false)

        XCTAssertNil(PowerEnforcement.correction(for: .off, given: current),
                     "with nothing switched on the app owns nothing")
    }

    // MARK: - Winning against another writer

    func testForcesIdleSleepBackToNeverWhenSomethingElseChangedIt() {
        let current = PowerSettings(sleepMinutes: 20, displaySleepMinutes: 0, disableSleep: true)

        let correction = PowerEnforcement.correction(for: allOn, given: current)

        XCTAssertEqual(correction?.sleepMinutes, 0)
    }

    func testForcesDisplaySleepBackToNeverWhenSomethingElseChangedIt() {
        let current = PowerSettings(sleepMinutes: 0, displaySleepMinutes: 15, disableSleep: true)

        let correction = PowerEnforcement.correction(for: allOn, given: current)

        XCTAssertEqual(correction?.displaySleepMinutes, 0)
    }

    func testForcesLidClosedBackOnWhenSomethingElseTurnedItOff() {
        let current = PowerSettings(sleepMinutes: 0, displaySleepMinutes: 0, disableSleep: false)

        let correction = PowerEnforcement.correction(for: allOn, given: current)

        XCTAssertEqual(correction?.disableSleep, true)
    }

    // MARK: - Staying out of the way

    func testLeavesSettingsTheUserDidNotSwitchOnAlone() {
        let keepAwakeOnly = PowerConfig(keepAwake: true,
                                        keepDisplayOn: false,
                                        stayAwakeWithLidClosed: false)
        let current = PowerSettings(sleepMinutes: 20, displaySleepMinutes: 15, disableSleep: false)

        let correction = PowerEnforcement.correction(for: keepAwakeOnly, given: current)

        XCTAssertEqual(correction?.sleepMinutes, 0, "the switch that is on must be forced")
        XCTAssertEqual(correction?.displaySleepMinutes, 15,
                       "the display setting is not ours while the switch is off")
        XCTAssertEqual(correction?.disableSleep, false,
                       "lid-close is not ours while the switch is off")
    }

    func testDriftInAnUnownedSettingAloneIsNotWorthAWrite() {
        let keepAwakeOnly = PowerConfig(keepAwake: true,
                                        keepDisplayOn: false,
                                        stayAwakeWithLidClosed: false)
        let current = PowerSettings(sleepMinutes: 0, displaySleepMinutes: 15, disableSleep: false)

        XCTAssertNil(PowerEnforcement.correction(for: keepAwakeOnly, given: current),
                     "someone changing the display timeout must not trigger a write")
    }
}
