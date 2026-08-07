import AppKit

// Menu-bar-only app: no dock icon, no main window. Settings temporarily
// switches the activation policy so its window can take focus.
let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
