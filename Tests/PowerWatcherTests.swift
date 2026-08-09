import XCTest

/// What makes the app a rule setter rather than a suggestion: something has to
/// notice that another writer moved the settings. The watcher is that something.
final class PowerWatcherTests: XCTestCase {
    private var directory: URL!
    private var file: URL!
    private var watcher: PowerWatcher!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kma-watch-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("PowerManagement.plist")
        try! Data("original".utf8).write(to: file)
    }

    override func tearDown() {
        watcher?.stop()
        watcher = nil
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testReactsWhenTheWatchedFileIsWritten() {
        let changed = expectation(description: "change seen")
        changed.assertForOverFulfill = false

        watcher = PowerWatcher(watching: [file], every: 60) { changed.fulfill() }
        watcher.start()

        try! Data("someone else changed it".utf8).write(to: file)

        wait(for: [changed], timeout: 5)
    }

    /// `pmset` replaces the preferences file rather than editing it in place, so
    /// a watcher holding a descriptor to the old file goes deaf after the first
    /// change — the one case that matters most.
    func testKeepsWatchingAfterTheFileIsReplacedAtomically() {
        let secondChange = expectation(description: "second change seen")
        secondChange.assertForOverFulfill = false
        var seen = 0

        watcher = PowerWatcher(watching: [file], every: 60) {
            seen += 1
            if seen >= 2 { secondChange.fulfill() }
        }
        watcher.start()

        try! Data("first".utf8).write(to: file, options: .atomic)
        try! Data("second".utf8).write(to: file, options: .atomic)

        wait(for: [secondChange], timeout: 5)
    }

    /// The file watch is the fast path, not the guarantee. A settings change
    /// that never touches this file still has to be caught.
    func testPollsOnItsOwnEvenWhenNothingTouchesTheFile() {
        let ticked = expectation(description: "polled")
        ticked.assertForOverFulfill = false

        watcher = PowerWatcher(watching: [file], every: 0.1) { ticked.fulfill() }
        watcher.start()

        wait(for: [ticked], timeout: 5)
    }

    /// macOS keeps the power settings in more than one file — a plain one and a
    /// per-machine one — and which of them a write lands in varies. Watching a
    /// single guessed path is how the fast path ends up silently dead.
    func testReactsToAChangeInAnyOfTheWatchedFiles() {
        let second = directory.appendingPathComponent("PowerManagement.UUID.plist")
        try! Data("original".utf8).write(to: second)

        let changed = expectation(description: "change seen in the second file")
        changed.assertForOverFulfill = false

        watcher = PowerWatcher(watching: [file, second], every: 60) { changed.fulfill() }
        watcher.start()

        try! Data("someone else changed it".utf8).write(to: second)

        wait(for: [changed], timeout: 5)
    }

    /// A path that does not exist yet must not stop the others from being
    /// watched — the per-machine file appears only once something writes it.
    func testWatchesTheFilesThatExistEvenWhenOneIsMissing() {
        let missing = directory.appendingPathComponent("not-created-yet.plist")

        let changed = expectation(description: "change seen")
        changed.assertForOverFulfill = false

        watcher = PowerWatcher(watching: [missing, file], every: 60) { changed.fulfill() }
        watcher.start()

        try! Data("someone else changed it".utf8).write(to: file)

        wait(for: [changed], timeout: 5)
    }

    func testStopsCallingBackOnceStopped() {
        var seen = 0
        watcher = PowerWatcher(watching: [file], every: 0.1) { seen += 1 }
        watcher.start()

        let settled = expectation(description: "watcher ran at least once")
        settled.assertForOverFulfill = false
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        wait(for: [settled], timeout: 5)

        watcher.stop()
        let after = seen

        let quiet = expectation(description: "quiet period elapsed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { quiet.fulfill() }
        wait(for: [quiet], timeout: 5)

        XCTAssertEqual(seen, after, "a stopped watcher must go silent")
    }
}
