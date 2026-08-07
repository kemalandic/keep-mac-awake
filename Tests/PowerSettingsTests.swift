import XCTest

/// Parsing is the only place the helper can silently misread the machine, and
/// the absent-SleepDisabled case is what broke the original shell script.
final class PmsetOutputTests: XCTestCase {
    /// Verbatim `pmset -g` output. Captured rather than hand-written, so the
    /// awkward lines are present — notably `Sleep On Power Button`, which also
    /// starts with "sleep".
    private let realOutput = """
    System-wide power settings:
     SleepDisabled\t\t0
    Currently in use:
     standby              1
     Sleep On Power Button 1
     autorestartatconnect 0
     autorestart          0
     powernap             1
     networkoversleep     0
     disksleep            10
     sleep                1 (sleep prevented by powerd, runningboardd)
     ttyskeepawake        1
     displaysleep         10
     tcpkeepalive         1
     lowpowermode         0
     womp                 1
    """

    func testRealPmsetOutput() {
        let settings = PmsetOutput.parse(realOutput)
        XCTAssertEqual(settings.sleepMinutes, 1, "the Sleep On Power Button line must not be mistaken for the sleep timer")
        XCTAssertEqual(settings.displaySleepMinutes, 10)
        XCTAssertFalse(settings.disableSleep)
    }

    func testSleepOnPowerButtonAloneDoesNotLookLikeSleep() {
        XCTAssertEqual(PmsetOutput.parse(" Sleep On Power Button 1").sleepMinutes, 0,
                       "a non-numeric value must not be treated as a match")
    }

    func testAbsentSleepDisabledLineMeansOff() {
        let output = """
        System-wide power settings:
        Currently in use:
         standby              0
         sleep                0 (sleep prevented by powerd)
         displaysleep         120
        """
        XCTAssertFalse(PmsetOutput.parse(output).disableSleep,
                       "an absent line means off")
    }

    func testReadsAllThreeValues() {
        let output = """
        System-wide power settings:
         SleepDisabled\t\t1
        Currently in use:
         sleep                0 (sleep prevented by powerd, caffeinate)
         displaysleep         15
        """
        let settings = PmsetOutput.parse(output)
        XCTAssertEqual(settings.sleepMinutes, 0)
        XCTAssertEqual(settings.displaySleepMinutes, 15)
        XCTAssertTrue(settings.disableSleep)
    }

    func testTrailingCommentaryIsIgnored() {
        let settings = PmsetOutput.parse(" sleep 30 (sleep prevented by X, Y)")
        XCTAssertEqual(settings.sleepMinutes, 30)
    }

    func testAlternateSpelling() {
        XCTAssertTrue(PmsetOutput.parse("disablesleep 1").disableSleep)
    }

    func testEmptyOutput() {
        XCTAssertEqual(PmsetOutput.parse(""),
                       PowerSettings(sleepMinutes: 0, displaySleepMinutes: 0, disableSleep: false))
    }
}
