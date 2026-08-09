import XCTest

final class FakePowerControl: PowerSettingsControlling {
    var settings = PowerSettings(sleepMinutes: 10, displaySleepMinutes: 5, disableSleep: false)
    var writes: [PowerSettings] = []
    var readError: Error?
    var writeError: Error?
    /// Writes that report success but leave the machine unchanged.
    var writesThatDoNotStick = 0

    func read() throws -> PowerSettings {
        if let readError { throw readError }
        return settings
    }

    func write(_ newSettings: PowerSettings) throws {
        if let writeError { throw writeError }
        writes.append(newSettings)
        if writesThatDoNotStick > 0 {
            writesThatDoNotStick -= 1
            return
        }
        settings = newSettings
    }
}

final class HelperServiceTests: XCTestCase {
    private var control: FakePowerControl!
    private var store: BaselineStore!
    private var storeURL: URL!
    private var service: HelperService!

    override func setUp() {
        super.setUp()
        control = FakePowerControl()
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kma-\(UUID().uuidString)")
            .appendingPathComponent("baseline.plist")
        store = BaselineStore(url: storeURL)
        service = HelperService(
            control: control,
            store: store,
            desired: DesiredStore(url: storeURL.deletingLastPathComponent()
                .appendingPathComponent("desired.plist")),
            pause: { _ in })
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
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

    private var keepAwakeOnly: PowerConfig {
        PowerConfig(keepAwake: true, keepDisplayOn: false, stayAwakeWithLidClosed: false)
    }

    // MARK: - Writing

    func testKeepAwakeStopsIdleSleepAndLeavesDisplayAlone() {
        apply(keepAwakeOnly)
        XCTAssertEqual(control.settings.sleepMinutes, 0)
        XCTAssertEqual(control.settings.displaySleepMinutes, 5, "the display setting must be untouched")
        XCTAssertFalse(control.settings.disableSleep)
    }

    func testLidClosedSetsDisableSleep() {
        apply(PowerConfig(keepAwake: true, keepDisplayOn: false, stayAwakeWithLidClosed: true))
        XCTAssertTrue(control.settings.disableSleep)
    }

    func testBaselineIsCapturedOnceFromTheMachinesOwnValues() {
        apply(keepAwakeOnly)
        XCTAssertEqual(store.load(),
                       PowerSettings(sleepMinutes: 10, displaySleepMinutes: 5, disableSleep: false))

        // A second change must not re-capture: the machine now shows our values.
        apply(PowerConfig(keepAwake: true, keepDisplayOn: true, stayAwakeWithLidClosed: false))
        XCTAssertEqual(store.load()?.sleepMinutes, 10, "the first real value must be preserved")
    }

    // MARK: - The whole point: settings persist

    /// The helper must never revert anything on its own.
    func testNothingIsRevertedWithoutAnExplicitOff() {
        apply(PowerConfig(keepAwake: true, keepDisplayOn: false, stayAwakeWithLidClosed: true))
        let afterApply = control.settings

        // Simulate the app quitting and a fresh helper starting later.
        let restarted = HelperService(
            control: control,
            store: store,
            desired: DesiredStore(url: storeURL.deletingLastPathComponent()
                .appendingPathComponent("desired.plist")),
            pause: { _ in })
        _ = restarted

        XCTAssertEqual(control.settings, afterApply, "the setting must be left alone")
        XCTAssertTrue(store.exists, "the baseline must be kept")
    }

    func testExplicitOffRestoresTheOriginalValues() {
        apply(PowerConfig(keepAwake: true, keepDisplayOn: true, stayAwakeWithLidClosed: true))
        apply(.off)

        XCTAssertEqual(control.settings,
                       PowerSettings(sleepMinutes: 10, displaySleepMinutes: 5, disableSleep: false))
        XCTAssertFalse(store.exists, "the baseline is released once everything is off")
    }

    func testTurningOneThingOffRestoresOnlyThatValue() {
        apply(PowerConfig(keepAwake: true, keepDisplayOn: true, stayAwakeWithLidClosed: true))
        apply(PowerConfig(keepAwake: true, keepDisplayOn: false, stayAwakeWithLidClosed: true))

        XCTAssertEqual(control.settings.sleepMinutes, 0, "keep awake must stay on")
        XCTAssertEqual(control.settings.displaySleepMinutes, 5, "the display returns to its original value")
        XCTAssertTrue(control.settings.disableSleep, "lid-closed must stay on")
        XCTAssertTrue(store.exists, "the baseline is kept while anything is still on")
    }

    // MARK: - Reading

    func testCurrentConfigReportsWhatTheMachineHas() {
        control.settings = PowerSettings(sleepMinutes: 0, displaySleepMinutes: 0, disableSleep: true)

        var reported: PowerConfig?
        let done = expectation(description: "config")
        service.currentConfig { data in
            reported = data.flatMap { try? PropertyListDecoder().decode(PowerConfig.self, from: $0) }
            done.fulfill()
        }
        wait(for: [done], timeout: 1)

        XCTAssertEqual(reported, PowerConfig(keepAwake: true,
                                             keepDisplayOn: true,
                                             stayAwakeWithLidClosed: true))
    }

    // MARK: - Failures

    func testRetriesUntilTheSettingSticks() {
        control.writesThatDoNotStick = 2
        let result = apply(keepAwakeOnly)

        XCTAssertTrue(result.ok)
        XCTAssertEqual(control.settings.sleepMinutes, 0)
        XCTAssertEqual(control.writes.count, 3)
    }

    func testReportsWhenTheSettingNeverSticks() {
        control.writesThatDoNotStick = 99
        let result = apply(keepAwakeOnly)

        XCTAssertFalse(result.ok)
        XCTAssertNotNil(result.message)
    }

    func testWriteFailureIsReported() {
        control.writeError = PmsetControl.Failure.nonZeroExit(1, "boom")
        let result = apply(keepAwakeOnly)

        XCTAssertFalse(result.ok)
        XCTAssertNotNil(result.message)
    }

    func testGarbageRequestIsRejected() {
        var result: (Bool, String?) = (true, nil)
        let done = expectation(description: "reply")
        service.apply(Data("not a plist".utf8)) { ok, message in
            result = (ok, message)
            done.fulfill()
        }
        wait(for: [done], timeout: 1)

        XCTAssertFalse(result.0)
        XCTAssertNotNil(result.1)
    }
}
