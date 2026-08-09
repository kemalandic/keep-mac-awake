import Foundation

// Root daemon, launched by launchd via SMAppService. It exists to write power
// settings a normal process is not allowed to write, and to keep them written.
//
// It runs continuously (RunAtLoad + KeepAlive) because it is the part that
// enforces the user's switches: on demand would mean the rule lapses at every
// reboot until someone opens the app, and the app is not required to run.
//
// What it still does not do: undo anything on its own. Nothing is reverted
// without an explicit "off" from the user — enforcing a rule and reverting one
// are opposite things.

let helperService = HelperService(control: PmsetControl(),
                                  store: BaselineStore(),
                                  desired: DesiredStore())

Log.helper.notice("""
helper started — version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?", privacy: .public)
""")

// A machine upgrading from a version that only wrote settings has switches on
// and no rule recorded. Adopt what is in effect before enforcing anything,
// otherwise those users stay unprotected until they happen to toggle something.
helperService.adoptSettingsInEffectAsRule()

// A reboot, a system update or another tool may have moved the settings while
// this daemon was not running. Assert the rule before serving anyone.
helperService.enforce()

// Where the power settings land on disk. Both are watched because which one a
// write goes to depends on the machine and the macOS version, and a wrong guess
// here fails silently. The timer behind them is the safety net for any route
// that touches neither.
let watcher = PowerWatcher(
    watching: PowerPreferences.files,
    every: 60
) {
    helperService.enforce()
}
watcher.start()

let listenerDelegate = HelperListenerDelegate(service: helperService)
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = listenerDelegate
listener.resume()

RunLoop.main.run()
