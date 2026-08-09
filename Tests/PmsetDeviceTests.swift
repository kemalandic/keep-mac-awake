import XCTest

/// DEVICE-ONLY. Reads the real machine.
///
/// The values are extracted a second way as well — with awk, whose matching is
/// case-sensitive and so cannot repeat a mistake the parser might make — and
/// compared. Agreement between two independent readings of live output is worth
/// more than any fixture.
final class PmsetDeviceTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["KMA_DEVICE_TESTS"] == "1",
            "Device test — run with the KeepMacAwakeDeviceTests scheme"
        )
    }

    func testParserAgreesWithAwkOnLiveOutput() throws {
        let ours = PmsetOutput.parse(try Self.shell("/usr/bin/pmset -g"))

        let sleep = try Self.awkValue("$1==\"sleep\" && $2 ~ /^[0-9]+$/")
        let displaySleep = try Self.awkValue("$1==\"displaysleep\"")
        let disableSleep = try Self.awkValue("tolower($1)==\"sleepdisabled\"")

        XCTAssertEqual(ours.sleepMinutes, sleep ?? 0, "our sleep reading disagrees with awk")
        XCTAssertEqual(ours.displaySleepMinutes, displaySleep ?? 0,
                       "our displaysleep reading disagrees with awk")
        XCTAssertEqual(ours.disableSleep, (disableSleep ?? 0) == 1,
                       "our disablesleep reading disagrees with awk")
    }

    /// Guards the test above: it proves nothing if the tricky line is absent.
    func testSleepOnPowerButtonLineIsPresentOnThisMachine() throws {
        let output = try Self.shell("/usr/bin/pmset -g")
        XCTAssertTrue(output.contains("Sleep On Power Button"),
                      "without this line the comparison above proves nothing")
    }

    /// Holds a real display-sleep assertion and checks we see it, cross-checked
    /// against grep counting the same lines. Fixtures cannot prove the parser
    /// still matches what this version of macOS actually prints.
    func testAssertionReadingAgreesWithGrepOnLiveOutput() throws {
        let caffeinate = Process()
        caffeinate.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        caffeinate.arguments = ["-d", "-t", "20"]
        try caffeinate.run()
        defer { caffeinate.terminate() }
        Thread.sleep(forTimeInterval: 1.5)

        let blockers = try PmsetControl().readAssertions()

        XCTAssertTrue(blockers.contains { $0.process == "caffeinate" && $0.keepsDisplayOn },
                      "a live caffeinate -d must show up as holding the display on")
        XCTAssertFalse(blockers.contains { $0.process == "powerd" },
                       "the OS's own bookkeeping must stay out of the report")

        let grepped = try Self.shell(
            "/usr/bin/pmset -g assertions | /usr/bin/grep -c 'PreventUserIdleDisplaySleep named'"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(blockers.filter(\.keepsDisplayOn).count, Int(grepped) ?? -1,
                       "our display-blocker count disagrees with grep")
    }

    private static func awkValue(_ condition: String) throws -> Int? {
        let script = "\(condition) { print $2; exit }"
        let output = try shell("/usr/bin/pmset -g | /usr/bin/awk '\(script)'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : Int(output)
    }

    private static func shell(_ command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
