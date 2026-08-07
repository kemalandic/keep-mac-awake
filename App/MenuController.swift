import AppKit

/// Owns the status item and its menu.
///
/// The checkmarks mirror what the *system* reports, not what this app last did,
/// so they stay honest after a reboot or after someone runs pmset by hand.
final class MenuController {
    private let onToggleKeepAwake: (Bool) -> Void
    private let onToggleDisplay: (Bool) -> Void
    private let onToggleLidClosed: (Bool) -> Void
    private let onOpenSettings: () -> Void

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private var config = PowerConfig.off

    private enum Tag: Int {
        case keepAwake = 1
        case keepDisplay
        case lidClosed
    }

    init(onToggleKeepAwake: @escaping (Bool) -> Void,
         onToggleDisplay: @escaping (Bool) -> Void,
         onToggleLidClosed: @escaping (Bool) -> Void,
         onOpenSettings: @escaping () -> Void) {
        self.onToggleKeepAwake = onToggleKeepAwake
        self.onToggleDisplay = onToggleDisplay
        self.onToggleLidClosed = onToggleLidClosed
        self.onOpenSettings = onOpenSettings
    }

    func install() {
        buildMenu()
        statusItem.menu = menu
        show(PowerConfig.off)
    }

    func show(_ config: PowerConfig) {
        self.config = config

        if let button = statusItem.button {
            let symbol = config.keepAwake ? "cup.and.saucer.fill" : "cup.and.saucer"
            button.image = NSImage(systemSymbolName: symbol,
                                   accessibilityDescription: "Keep Mac Awake")
            button.imagePosition = .imageOnly
        }

        menu.item(withTag: Tag.keepAwake.rawValue)?.state = config.keepAwake ? .on : .off
        menu.item(withTag: Tag.keepDisplay.rawValue)?.state = config.keepDisplayOn ? .on : .off
        menu.item(withTag: Tag.lidClosed.rawValue)?.state = config.stayAwakeWithLidClosed ? .on : .off
    }

    private func buildMenu() {
        let keepAwake = NSMenuItem(title: "Keep Awake",
                                   action: #selector(toggleKeepAwake),
                                   keyEquivalent: "k")
        keepAwake.target = self
        keepAwake.tag = Tag.keepAwake.rawValue
        menu.addItem(keepAwake)

        menu.addItem(.separator())

        let display = NSMenuItem(title: "Keep display on",
                                 action: #selector(toggleDisplay),
                                 keyEquivalent: "")
        display.target = self
        display.tag = Tag.keepDisplay.rawValue
        menu.addItem(display)

        let lid = NSMenuItem(title: "Stay awake with lid closed",
                             action: #selector(toggleLidClosed),
                             keyEquivalent: "")
        lid.target = self
        lid.tag = Tag.lidClosed.rawValue
        menu.addItem(lid)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(openSettings),
                                  keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(NSMenuItem(title: "Quit Keep Mac Awake",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    @objc private func toggleKeepAwake() { onToggleKeepAwake(!config.keepAwake) }
    @objc private func toggleDisplay() { onToggleDisplay(!config.keepDisplayOn) }
    @objc private func toggleLidClosed() { onToggleLidClosed(!config.stayAwakeWithLidClosed) }
    @objc private func openSettings() { onOpenSettings() }
}
