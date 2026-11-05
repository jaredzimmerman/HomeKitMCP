import AppKit

/// Owns the menu bar icon and menu. Runs inside the Catalyst app's process (main thread only).
@objc(HKBStatusBarController)
final class StatusBarController: NSObject, HKBMenuBar, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var lines: [String] = ["Starting"]
    private var ok = true
    private var logPath = ""
    private var loginEnabled: () -> Bool = { false }
    private var toggleLogin: () -> Bool = { false }

    required override init() {
        super.init()
    }

    func setup(logPath: String, loginEnabled: @escaping () -> Bool, toggleLogin: @escaping () -> Bool) {
        self.logPath = logPath
        self.loginEnabled = loginEnabled
        self.toggleLogin = toggleLogin
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.toolTip = "HomeKit Bridge"
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
        rebuild()

        // Menu-bar only, but HomeKit refuses writes from a Catalyst app with no visible scene
        // (HMError 80, "Handler does not support background access"). So the launch scene's window is
        // kept on screen but made invisible: transparent, click-through, 1x1, above normal windows so
        // nothing covers it, on every Space, and out of the window cycle and Mission Control.
        // UIKit can reset these, so they are reapplied on occlusion changes and after every event
        // the app handles (a handful of windows: cheap, and a no-op once applied).
        let center = NotificationCenter.default
        windowObservers = [
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { note in
                (note.object as? NSWindow).map(StatusBarController.conceal)
            },
            center.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { _ in
                NSApp.windows.forEach(StatusBarController.conceal)
            },
        ]
        DispatchQueue.main.async { NSApp.windows.forEach(StatusBarController.conceal) }
    }

    private var windowObservers: [NSObjectProtocol] = []

    private static let concealedBehavior: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

    /// Scene windows are the app's titled windows; menus and the status item are not.
    private static func conceal(_ window: NSWindow) {
        guard window.styleMask.contains(.titled), !(window is NSPanel) else { return }
        if window.alphaValue != 0 { window.alphaValue = 0 }
        if !window.ignoresMouseEvents { window.ignoresMouseEvents = true }
        if window.hasShadow { window.hasShadow = false }
        if !window.isExcludedFromWindowsMenu { window.isExcludedFromWindowsMenu = true }
        if window.collectionBehavior != concealedBehavior { window.collectionBehavior = concealedBehavior }
        if window.level != .floating { window.level = .floating }
        if let screen = NSScreen.screens.first {
            let spot = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: 1, height: 1)
            if window.frame != spot { window.setFrame(spot, display: false) }
        }
        if !window.isVisible { window.orderFrontRegardless() }
    }

    func update(lines: [String], ok: Bool) {
        self.lines = lines
        self.ok = ok
        rebuild()
    }

    // Refresh the login checkmark each time the menu opens (it can change in System Settings).
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    private func rebuild() {
        statusItem?.button?.image = icon()
        menu.removeAllItems()
        menu.addItem(NSMenuItem.sectionHeader(title: "HomeKit Bridge"))
        for line in lines {
            let info = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLoginAction), keyEquivalent: "")
        login.target = self
        login.state = loginEnabled() ? .on : .off
        menu.addItem(login)
        let log = NSMenuItem(title: "Show Activity Log in Finder", action: #selector(showLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit HomeKit Bridge", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func icon() -> NSImage? {
        let name = ok ? "homekit" : "exclamationmark.triangle"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "HomeKit Bridge")
            ?? NSImage(systemSymbolName: "house", accessibilityDescription: "HomeKit Bridge")
        image?.isTemplate = true
        return image
    }

    @objc private func toggleLoginAction() {
        _ = toggleLogin()
        rebuild()
    }

    @objc private func showLog() {
        let file = URL(fileURLWithPath: logPath)
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            // No writes logged yet: open the folder (or its parent) instead.
            let folder = file.deletingLastPathComponent()
            let target = FileManager.default.fileExists(atPath: folder.path) ? folder : folder.deletingLastPathComponent()
            NSWorkspace.shared.open(target)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
