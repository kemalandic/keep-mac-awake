import Foundation

/// Accepts XPC connections from exactly one caller: our signed app.
///
/// A client going away is not an event: the settings this daemon writes are
/// meant to outlive both the app and the daemon itself.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: HelperService

    init(service: HelperService) {
        self.service = service
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Reject anything not signed by us and carrying our app's identifier.
        connection.setCodeSigningRequirement(HelperConstants.clientRequirement)

        connection.exportedInterface = NSXPCInterface(with: PowerHelperProtocol.self)
        connection.exportedObject = service

        Log.helper.notice("client connected")
        connection.resume()
        return true
    }
}
