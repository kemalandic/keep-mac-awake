import XCTest

/// An XPC call to a service launchd cannot start neither answers nor fails: the
/// message sits in the queue while launchd keeps deferring the spawn. Without a
/// deadline the app hangs there forever — running, visible in the menu bar,
/// doing nothing and saying nothing.
final class DeadlineTests: XCTestCase {
    func testGivesBackTheResultWhenTheWorkFinishesInTime() async {
        let result = await Deadline.run(within: 5) { "answered" }

        XCTAssertEqual(result, "answered")
    }

    func testGivesUpWhenTheWorkOutlivesTheDeadline() async {
        let result = await Deadline.run(within: 0.1) { () -> String in
            try? await Task.sleep(for: .seconds(30))
            return "too late"
        }

        XCTAssertNil(result)
    }

    /// Giving up has to be prompt — a deadline that still waits for the hung
    /// call to finish is not a deadline.
    func testStopsWaitingAtTheDeadlineRatherThanForTheWork() async {
        let started = Date()

        _ = await Deadline.run(within: 0.2) { () -> String in
            try? await Task.sleep(for: .seconds(30))
            return "too late"
        }

        XCTAssertLessThan(Date().timeIntervalSince(started), 5,
                          "the deadline must cut the wait short")
    }

    /// The case that actually happens, and the one a `Task.sleep` stand-in
    /// cannot reproduce: an XPC reply that never arrives leaves a checked
    /// continuation unresumed, and cancelling a task does not resume it. Work
    /// like that never finishes, so anything that waits for it waits forever.
    func testGivesUpOnWorkThatCannotBeCancelled() async {
        let returned = expectation(description: "the deadline returned")

        Task {
            _ = await Deadline.run(within: 0.2) { () -> String in
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                return "never arrives"
            }
            returned.fulfill()
        }

        await fulfillment(of: [returned], timeout: 5)
    }

    func testAnOptionalResultSurvivesTheRoundTrip() async {
        let answered: String? = await Deadline.run(within: 5) { () -> String? in "yes" } ?? nil
        let declined: String? = await Deadline.run(within: 5) { () -> String? in nil } ?? nil

        XCTAssertEqual(answered, "yes")
        XCTAssertNil(declined, "work that answers 'no' is not the same as no answer")
    }
}
