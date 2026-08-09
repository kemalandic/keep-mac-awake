import XCTest

/// The power settings are written to `com.apple.PowerManagement.plist` and to a
/// per-machine `com.apple.PowerManagement.<UUID>.plist`. The UUID cannot be
/// hard-coded, so the files are found rather than guessed.
final class PowerPreferencesTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kma-prefs-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func write(_ name: String) {
        try! Data("x".utf8).write(to: directory.appendingPathComponent(name))
    }

    func testFindsThePlainPreferencesFile() {
        write("com.apple.PowerManagement.plist")

        let found = PowerPreferences.candidates(in: directory).map(\.lastPathComponent)

        XCTAssertEqual(found, ["com.apple.PowerManagement.plist"])
    }

    func testFindsThePerMachineFileWhoseNameCannotBeKnownInAdvance() {
        write("com.apple.PowerManagement.1B2C3D4E-5F60-4718-9A2B-3C4D5E6F7A8B.plist")

        let found = PowerPreferences.candidates(in: directory).map(\.lastPathComponent)

        XCTAssertEqual(found,
                       ["com.apple.PowerManagement.1B2C3D4E-5F60-4718-9A2B-3C4D5E6F7A8B.plist"])
    }

    func testIgnoresUnrelatedPreferences() {
        write("com.apple.PowerManagement.plist")
        write("com.apple.loginwindow.plist")
        write("com.apple.TimeMachine.plist")

        let found = PowerPreferences.candidates(in: directory).map(\.lastPathComponent)

        XCTAssertEqual(found, ["com.apple.PowerManagement.plist"])
    }

    func testReturnsNothingRatherThanFailingWhenTheDirectoryCannotBeRead() {
        let missing = directory.appendingPathComponent("no-such-directory")

        XCTAssertEqual(PowerPreferences.candidates(in: missing), [])
    }
}
