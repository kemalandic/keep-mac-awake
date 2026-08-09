import Foundation

/// Runs its body at most once.
///
/// Used wherever two racing paths can both try to finish the same continuation:
/// resuming one twice crashes, and never resuming it hangs the caller forever.
final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
