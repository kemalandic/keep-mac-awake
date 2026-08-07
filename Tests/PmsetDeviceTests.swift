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
