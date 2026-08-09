import XCTest

/// `pmset` writes settings; an `IOPMAssertion` overrides them while it is held.
/// A machine can therefore obey every setting this app writes and still refuse
/// to sleep, and nothing in the settings explains why. Reading who holds the
/// assertions is the only way the app can tell the user what is really going on.
///
/// Fixtures are verbatim captures of real `pmset -g assertions` output.
final class SleepBlockerTests: XCTestCase {
    /// Captured while `caffeinate -d` was running, so the display-sleep line is
    /// real rather than imagined.
    private let realOutput = """
    Listed by owning process:
       pid 350(powerd): [0x0002d55300018d73] 01:04:07 PreventUserIdleSystemSleep named: "Powerd - Prevent sleep while display is on"
       pid 73062(caffeinate): [0x0002e45900058f2a] 00:00:02 PreventUserIdleDisplaySleep named: "caffeinate command-line tool"
    \tDetails: caffeinate asserting for 6 secs
    \tLocalized=THE CAFFEINATE TOOL IS PREVENTING SLEEP.
    \tTimeout will fire in 4 secs Action=TimeoutActionRelease
       pid 72396(caffeinate): [0x0002e3a800018f22] 00:02:58 PreventUserIdleSystemSleep named: "caffeinate command-line tool"
    \tDetails: caffeinate asserting for 300 secs
    \tLocalized=THE CAFFEINATE TOOL IS PREVENTING SLEEP.
    \tTimeout will fire in 121 secs Action=TimeoutActionRelease
       pid 410(WindowServer): [0x0002d55300098d72] 00:02:58 UserIsActive named: "com.apple.iohideventsystem.queue.tickle serviceID:100000aa5 service:AppleHIDKeyboardEventDriverV2 product:Apple Internal Keyboard / Trackpad eventType:3"
    \tTimeout will fire in 421 secs Action=TimeoutActionRelease
    No kernel assertions.
    """

    func testFindsTheProcessHoldingTheDisplayAwake() {
        let blockers = PmsetOutput.parseAssertions(realOutput)

        let display = blockers.filter(\.keepsDisplayOn)
        XCTAssertEqual(display.count, 1)
        XCTAssertEqual(display.first?.process, "caffeinate")
        XCTAssertEqual(display.first?.reason, "caffeinate command-line tool")
    }

    func testFindsTheProcessHoldingTheSystemAwake() {
        let blockers = PmsetOutput.parseAssertions(realOutput)

        XCTAssertTrue(blockers.contains { $0.process == "caffeinate" && !$0.keepsDisplayOn })
    }

    /// powerd holds this on every Mac whose display is on. Reporting the
    /// operating system's own bookkeeping as "an app is keeping you awake"
    /// would be noise on a healthy machine, and would bury the real culprit.
    func testIgnoresTheOperatingSystemsOwnBookkeeping() {
        let blockers = PmsetOutput.parseAssertions(realOutput)

        XCTAssertFalse(blockers.contains { $0.process == "powerd" })
    }

    /// UserIsActive means someone touched the keyboard. It is not a reason the
    /// machine is refusing to sleep.
    func testIgnoresAssertionsThatDoNotPreventSleep() {
        let blockers = PmsetOutput.parseAssertions(realOutput)

        XCTAssertFalse(blockers.contains { $0.process == "WindowServer" })
    }

    func testDetailLinesAreNotMistakenForAssertions() {
        let blockers = PmsetOutput.parseAssertions(realOutput)

        XCTAssertEqual(blockers.count, 2, "two caffeinate assertions, nothing else")
    }

    func testAQuietMachineHasNoBlockers() {
        let quiet = """
        Listed by owning process:
           pid 350(powerd): [0x0002d55300018d73] 01:04:07 PreventUserIdleSystemSleep named: "Powerd - Prevent sleep while display is on"
        No kernel assertions.
        """

        XCTAssertEqual(PmsetOutput.parseAssertions(quiet), [])
    }

    func testEmptyOutputIsNotAFailure() {
        XCTAssertEqual(PmsetOutput.parseAssertions(""), [])
    }
}
