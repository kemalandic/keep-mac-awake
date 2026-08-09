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

    // MARK: - Naming what the user actually recognises

    /// `runningboardd` holds assertions on behalf of other apps, the way powerd
    /// does for the system. Naming the broker tells the user nothing: the app
    /// they recognise is buried in a string of internal bookkeeping, which also
    /// carries identifiers worth not putting on screen.
    ///
    /// Shaped exactly like real output; the instance numbers are placeholders.
    private let brokered = """
    Listed by owning process:
       pid 502(runningboardd): [0x0002e45900058f2a] 00:04:11 PreventUserIdleSystemSleep named: "app<application.com.apple.Safari.111111111.222222222(501)>-419-49457-76904:Shared Background Assertion 16 for com.apple.Safari(FinishTask)"
    """

    func testNamesTheAppRatherThanTheBrokerHoldingForIt() {
        let blocker = PmsetOutput.parseAssertions(brokered).first

        XCTAssertEqual(blocker?.displayName, "Safari")
    }

    func testSaysWhichBrokerIsHoldingIt() {
        let blocker = PmsetOutput.parseAssertions(brokered).first

        XCTAssertEqual(blocker?.displayDetail, "via runningboardd")
    }

    /// The internal bookkeeping carries a user id and installation identifiers.
    /// None of it means anything to the user, and it is not ours to display.
    func testTheInternalBookkeepingNeverReachesTheScreen() {
        let blocker = PmsetOutput.parseAssertions(brokered).first

        XCTAssertFalse(blocker?.displayDetail.contains("501") ?? true)
        XCTAssertFalse(blocker?.displayDetail.contains("Assertion 16") ?? true)
    }

    /// When the holder is the thing itself, its own description is the most
    /// useful thing to show — no cleverness needed.
    func testKeepsAPlainDescriptionAsItIs() {
        let blocker = PmsetOutput.parseAssertions(realOutput).first { $0.keepsDisplayOn }

        XCTAssertEqual(blocker?.displayName, "caffeinate")
        XCTAssertEqual(blocker?.displayDetail, "caffeinate command-line tool")
    }

    // MARK: - One row per app, because that is the question being asked

    /// The question this answers is "which app is keeping my Mac awake". An app
    /// that holds both kinds is one answer, not two: listing it twice answers
    /// the same question twice, and at three apps holding two kinds each the
    /// list reads as though it were repeating itself.
    func testAnAppHoldingBothKindsIsOneEntry() {
        let summary = SleepBlocker.summarised(PmsetOutput.parseAssertions(realOutput))

        XCTAssertEqual(summary.count, 1)
        XCTAssertEqual(summary.first?.name, "caffeinate")
    }

    func testAnEntrySaysBothOfTheThingsItIsHolding() {
        let summary = SleepBlocker.summarised(PmsetOutput.parseAssertions(realOutput))

        XCTAssertEqual(summary.first?.headline,
                       "Holding the display on and the system awake")
    }

    func testAnEntryHoldingOnlyTheDisplaySaysSo() {
        let displayOnly = """
        Listed by owning process:
           pid 100(caffeinate): [0x1] 00:00:02 PreventUserIdleDisplaySleep named: "caffeinate command-line tool"
        """

        let summary = SleepBlocker.summarised(PmsetOutput.parseAssertions(displayOnly))

        XCTAssertEqual(summary.first?.headline, "Holding the display on")
    }

    func testAnEntryHoldingOnlyTheSystemSaysSo() {
        let systemOnly = """
        Listed by owning process:
           pid 100(caffeinate): [0x1] 00:00:02 PreventUserIdleSystemSleep named: "caffeinate command-line tool"
        """

        let summary = SleepBlocker.summarised(PmsetOutput.parseAssertions(systemOnly))

        XCTAssertEqual(summary.first?.headline, "Holding the system awake")
    }

    /// Two runs of the same tool are one answer, not two.
    func testTheSameHolderTwiceOverIsStillOneEntry() {
        let twice = """
        Listed by owning process:
           pid 100(caffeinate): [0x1] 00:00:02 PreventUserIdleSystemSleep named: "caffeinate command-line tool"
           pid 200(caffeinate): [0x2] 00:01:02 PreventUserIdleSystemSleep named: "caffeinate command-line tool"
        """

        XCTAssertEqual(SleepBlocker.summarised(PmsetOutput.parseAssertions(twice)).count, 1)
    }

    func testDifferentAppsStayApart() {
        let two = """
        Listed by owning process:
           pid 100(caffeinate): [0x1] 00:00:02 PreventUserIdleSystemSleep named: "caffeinate command-line tool"
           pid 502(runningboardd): [0x2] 00:04:11 PreventUserIdleDisplaySleep named: "app<application.com.apple.Safari.1.2(501)>:Shared Background Assertion for com.apple.Safari(FinishTask)"
        """

        let summary = SleepBlocker.summarised(PmsetOutput.parseAssertions(two))

        XCTAssertEqual(summary.map(\.name).sorted(), ["Safari", "caffeinate"])
    }

    func testTheDescriptionSurvivesGrouping() {
        let summary = SleepBlocker.summarised(PmsetOutput.parseAssertions(realOutput))

        XCTAssertEqual(summary.first?.detail, "caffeinate command-line tool")
    }

    func testAnOverlongDescriptionIsCutRatherThanWrappedAcrossTheWindow() {
        let long = String(repeating: "verbose ", count: 40)
        let output = """
        Listed by owning process:
           pid 900(something): [0x1] 00:00:01 PreventUserIdleSystemSleep named: "\(long)"
        """

        let detail = PmsetOutput.parseAssertions(output).first?.displayDetail ?? ""

        XCTAssertLessThanOrEqual(detail.count, 80)
        XCTAssertTrue(detail.hasSuffix("…"))
    }
}
