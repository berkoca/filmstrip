import AppKit
import FilmstripCore
import FilmstripPlatform

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
        isEnabled = enabled
    }

    required init(coder: NSCoder) {
        fatalError("not used")
    }

    @objc private func run() { handler() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    let manager = WindowManager()
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        installSignalHandlers()
        if AX.isTrusted(prompt: false) {
            manager.start()
        } else {
            askForPermission()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.restoreAllWindows()
    }

    // MARK: Permission

    private func askForPermission() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Filmstrip needs Accessibility access"
        alert.informativeText = """
        macOS only lets an app move other apps' windows through Accessibility. \
        Turn Filmstrip on in System Settings → Privacy & Security → Accessibility. \
        Filmstrip starts by itself as soon as the switch is on.

        If Filmstrip is already in the list from an earlier build, remove it with the minus button and add it again.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            _ = AX.isTrusted(prompt: true)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard AX.isTrusted(prompt: false) else { return }
            timer.invalidate()
            self?.permissionTimer = nil
            self?.manager.start()
        }
    }

    // MARK: Quitting cleanly

    /// On Ctrl-C or `kill`, bring parked windows back before exiting.
    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.manager.restoreAllWindows()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "Filmstrip")
            image?.isTemplate = true
            button.image = image
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
    }

    /// The menu is rebuilt each time it opens, so it always shows the current settings.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let m = manager

        if !AX.isTrusted(prompt: false) {
            menu.addItem(ClosureMenuItem("Grant Accessibility Access…") { [weak self] in self?.askForPermission() })
            menu.addItem(.separator())
        } else if m.isStarted && !m.inputAvailable {
            menu.addItem(ClosureMenuItem("Shortcuts unavailable — restart Filmstrip", enabled: false) {})
            menu.addItem(.separator())
        }

        let status = m.isEnabled ? "Tiling \(m.windowCount) window\(m.windowCount == 1 ? "" : "s")" : "Paused"
        menu.addItem(ClosureMenuItem(status, enabled: false) {})
        menu.addItem(ClosureMenuItem(m.isEnabled ? "Pause  (⌃⌥Q)" : "Resume  (⌃⌥Q)") { m.setEnabled(!m.isEnabled) })
        menu.addItem(ClosureMenuItem("Re-arrange Windows") { m.rescan() })
        menu.addItem(.separator())


        let minimapMenu = NSMenu()
        for mode in MinimapMode.allCases {
            minimapMenu.addItem(ClosureMenuItem(mode.title, checked: m.minimapMode == mode) { m.minimapMode = mode })
        }
        minimapMenu.addItem(.separator())
        for size in MinimapSize.allCases {
            minimapMenu.addItem(ClosureMenuItem(size.title, checked: m.minimapSize == size) { m.minimapSize = size })
        }
        minimapMenu.addItem(.separator())
        let alwaysShown = m.minimapMode == .always
        minimapMenu.addItem(ClosureMenuItem("Windows Stop Above the Minimap", checked: !m.windowsUnderMinimap, enabled: alwaysShown) {
            m.windowsUnderMinimap = false
        })
        minimapMenu.addItem(ClosureMenuItem("Windows Reach the Dock (Minimap on Top)", checked: m.windowsUnderMinimap, enabled: alwaysShown) {
            m.windowsUnderMinimap = true
        })
        menu.addItem(submenu("Minimap", minimapMenu))

        let centerMenu = NSMenu()
        let centerTitles: [(CenterMode, String)] = [(.never, "Never"), (.onOverflow, "When it doesn't fit"), (.always, "Always")]
        for (mode, title) in centerTitles {
            centerMenu.addItem(ClosureMenuItem(title, checked: m.config.centerMode == mode) { m.setCenterMode(mode) })
        }
        menu.addItem(submenu("Centre Focused Window", centerMenu))

        let gapMenu = NSMenu()
        for gap in [0.0, 4, 8, 12, 16, 24] {
            gapMenu.addItem(ClosureMenuItem("\(Int(gap)) pt", checked: m.config.gap == gap) { m.setGap(gap) })
        }
        menu.addItem(submenu("Gaps", gapMenu))

        menu.addItem(ClosureMenuItem("Invert Scroll Direction", checked: m.invertScroll) { m.invertScroll.toggle() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Keyboard Shortcuts…") { [weak self] in self?.showShortcuts() })
        menu.addItem(ClosureMenuItem("About Filmstrip") { [weak self] in self?.showAbout() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Quit Filmstrip") { NSApp.terminate(nil) })
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.autoenablesItems = false // otherwise AppKit re-enables items we disabled
        item.submenu = menu
        return item
    }

    private func showShortcuts() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Keyboard Shortcuts"
        alert.informativeText = "Hold Control and Option (⌃⌥) with each key."
        let text = Bindings.reference.map { "\($0.keys.padding(toLength: 20, withPad: " ", startingAt: 0))\($0.action)" }.joined(separator: "\n")
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.frame = NSRect(x: 0, y: 0, width: 380, height: CGFloat(Bindings.reference.count) * 17)
        alert.accessoryView = field
        alert.runModal()
    }

    private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let alert = NSAlert()
        alert.messageText = "Filmstrip \(version)"
        alert.informativeText = "A scrolling window manager for macOS. Windows sit side by side on an endless strip; you scroll.\n\nOpen source under the MIT license."
        alert.runModal()
    }
}
