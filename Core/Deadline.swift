import Foundation

/// Puts a ceiling on how long the app will wait for an answer.
///
/// An XPC call to a service launchd cannot start neither answers nor fails: the
/// message waits in the queue while launchd keeps deferring the spawn. Without
/// a ceiling the app hangs there — running, visible in the menu bar, doing
/// nothing and saying nothing, which reads to the user as "this app is broken".
enum Deadline {
    /// The result of `work`, or nil if it did not finish in time.
    ///
    /// Deliberately not a task group. A group waits for every child before it
    /// closes, even after `cancelAll()` — and the work being guarded here is
    /// exactly the kind that cannot be cancelled: a continuation waiting on a
    /// reply that never comes is not resumed by cancellation, so it never
    /// finishes and the group never returns. The whole deadline would be
    /// defeated by the thing it exists to defend against.
    ///
    /// So the loser is abandoned rather than awaited. It may sit there until
    /// its reply arrives or its connection is torn down; the caller does not
    /// wait to find out which.
    ///
    /// A nil result means "no answer", which is not the same as an answer of
    /// nil: callers working with optional results need to keep the two apart.
    static func run<T: Sendable>(within seconds: Double,
                                 _ work: @escaping @Sendable () async -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = Once()

            Task {
                let value = await work()
                once.run { continuation.resume(returning: value) }
            }

            Task {
                try? await Task.sleep(for: .seconds(seconds))
                once.run { continuation.resume(returning: nil) }
            }
        }
    }
}
