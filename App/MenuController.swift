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

    /// Showing "everything off" when the helper cannot be reached is the one
    /// dishonest thing this menu could do: the settings are still written into
    /// the system, so the user reads "off", sees the Mac stay awake, and
    /// concludes the app is broken. Say "unknown" instead.
    enum State: Equatable {
        case known(PowerConfig)
        case unknown
    }

    private enum Tag: Int {
        case keepAwake = 1
        case keepDisplay
        case lidClosed
        case unknownNotice
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
        show(.unknown)
    }

    func show(_ state: State) {
        switch state {
        case .known(let config):
            self.config = config
            showButton(symbol: config.keepAwake ? "cup.and.saucer.fill" : "cup.and.saucer")
            menu.item(withTag: Tag.unknownNotice.rawValue)?.isHidden = true

            menu.item(withTag: Tag.keepAwake.rawValue)?.state = config.keepAwake ? .on : .off
            menu.item(withTag: Tag.keepDisplay.rawValue)?.state = config.keepDisplayOn ? .on : .off
            menu.item(withTag: Tag.lidClosed.rawValue)?.state =
                config.stayAwakeWithLidClosed ? .on : .off

        case .unknown:
            showButton(symbol: "cup.and.saucer")
            menu.item(withTag: Tag.unknownNotice.rawValue)?.isHidden = false

            // A dash, not an empty box: whatever is written into the system is
            // still in effect, we simply cannot read it right now.
            for tag in [Tag.keepAwake, .keepDisplay, .lidClosed] {
                menu.item(withTag: tag.rawValue)?.state = .mixed
            }
        }
    }

    private func showButton(symbol: String) {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: symbol,
                               accessibilityDescription: "Keep Mac Awake")
        button.imagePosition = .imageOnly
    }

    private func buildMenu() {
        let notice = NSMenuItem(title: "Helper not responding — settings unknown",
                                action: nil,
                                keyEquivalent: "")
        notice.isEnabled = false
        notice.tag = Tag.unknownNotice.rawValue
        menu.addItem(notice)

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
