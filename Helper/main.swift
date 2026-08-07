import Foundation

// Root daemon, launched by launchd via SMAppService. It exists only to write
// power settings a normal process is not allowed to write.
//
// It starts on demand, serves the app, and sits idle. It does not watch the
// app, does not undo anything at boot, and does not clean up on exit — the
// settings it writes are meant to outlive both it and the app.

let helperService = HelperService(control: PmsetControl(), store: BaselineStore())

Log.helper.notice("""
helper started — version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?", privacy: .public)
""")

let listenerDelegate = HelperListenerDelegate(service: helperService)
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = listenerDelegate
listener.resume()

RunLoop.main.run()
