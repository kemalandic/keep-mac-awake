import Foundation

/// The machine's own power settings from before we first changed anything, so
/// switching everything off can put them back exactly.
///
/// This is written once and read on explicit "off". It is deliberately NOT
/// consulted at boot or when the app quits: the settings we write are meant to
/// outlive the app, and restoring them behind the user's back is precisely the
/// behaviour this app must not have.
final class BaselineStore {
    static let defaultURL = URL(
        fileURLWithPath: "/Library/Application Support/ai.pakslab.keep-mac-awake/baseline.plist")

    private let url: URL

    init(url: URL = BaselineStore.defaultURL) {
        self.url = url
    }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    func load() -> PowerSettings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(PowerSettings.self, from: data)
    }

    func save(_ settings: PowerSettings) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(settings)

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: url.path)
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
