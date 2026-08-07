import Foundation

enum HelperConstants {
    static let machServiceName = "ai.pakslab.keep-mac-awake.helper"
    static let plistName = "ai.pakslab.keep-mac-awake.helper.plist"
    static let appBundleID = "ai.pakslab.keep-mac-awake"
    static let teamID = "CNRZ47Y629"

    /// Only a binary signed by us, carrying our app's identifier, may connect.
    static let clientRequirement = """
    anchor apple generic \
    and identifier "\(appBundleID)" \
    and certificate leaf[subject.OU] = "\(teamID)"
    """
}

/// The privileged helper's entire surface area.
///
/// Note what is NOT here: nothing about the app being alive. The helper writes
/// system settings and forgets about them. It never undoes anything on its own —
/// not when the app quits, not when the connection drops, not at boot. The
/// settings belong to the machine, not to a running process.
@objc protocol PowerHelperProtocol {
    /// Applies the requested configuration, capturing the machine's own values
    /// the first time so an explicit "off" can put them back.
    func apply(_ configData: Data, reply: @escaping (Bool, String?) -> Void)

    /// What the system currently reports, so the menu can show the truth rather
    /// than what this app last remembered.
    func currentConfig(reply: @escaping (Data?) -> Void)

    /// CFBundleVersion of the running helper, for update detection.
    func helperVersion(reply: @escaping (String) -> Void)
}
