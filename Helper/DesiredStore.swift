import Foundation

/// The rule the user set, written down so the helper can keep enforcing it
/// after the app quits and after a reboot.
///
/// The counterpart of `BaselineStore`: that one remembers where the machine
/// came from, this one remembers where it must stay. Both are root-only, and
/// both are released together when every switch goes off — at that point the
/// app claims nothing and enforces nothing.
final class DesiredStore {
    static let defaultURL = URL(
        fileURLWithPath: "/Library/Application Support/ai.pakslab.keep-mac-awake/desired.plist")

    private let url: URL

    init(url: URL = DesiredStore.defaultURL) {
        self.url = url
    }

    func load() -> PowerConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(PowerConfig.self, from: data)
    }

    func save(_ config: PowerConfig) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(config)

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
