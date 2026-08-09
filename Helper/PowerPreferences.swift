import Foundation

/// Where macOS keeps the power settings on disk.
///
/// There are two: `com.apple.PowerManagement.plist` and a per-machine
/// `com.apple.PowerManagement.<UUID>.plist`. Which one a write lands in depends
/// on the machine and the macOS version, so both are found rather than guessed
/// — a hard-coded path that turns out to be wrong fails silently, which is how
/// a watcher ends up watching nothing.
enum PowerPreferences {
    static let directory = URL(fileURLWithPath: "/Library/Preferences")

    private static let prefix = "com.apple.PowerManagement"
    private static let suffix = ".plist"

    static var files: [URL] { candidates(in: directory) }

    static func candidates(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }
            .sorted()
            .map(directory.appendingPathComponent)
    }
}
