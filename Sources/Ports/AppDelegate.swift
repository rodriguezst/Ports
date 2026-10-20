import AppKit
import Combine
import SwiftUI
import PortsCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: AppStore!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var observation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationMenu()
        store = AppStore()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "Ports"
        if let image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "Ports") {
            image.isTemplate = true
            statusItem.button?.image = image
        } else { statusItem.button?.title = "P" }
        observation = store.$forwardings.combineLatest(store.$states).sink { [weak self] connections, states in
            self?.updateMenu(connections: connections, states: states)
        }
        let notifications = NSWorkspace.shared.notificationCenter
        notifications.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        notifications.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        if store.forwardings.isEmpty || store.configurationUnavailable { showSettings() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store.hasRunningSessions else {
            store.shutdown {}
            return .terminateNow
        }
        store.shutdown { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func updateMenu(connections: [Forwarding], states: [UUID: TunnelState]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let connected = connections.filter { states[$0.id] == .connected }.count
        let enabled = connections.filter(\.isEnabled).count
        let heading = NSMenuItem(title: "Ports · \(connected) connected", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())
        if connections.isEmpty {
            let empty = NSMenuItem(title: "No port forwardings configured", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for connection in connections {
            let state = states[connection.id] ?? .disabled
            let item = NSMenuItem(title: "\(connection.label) — \(state.title)", action: #selector(toggleForwarding(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = connection.id.uuidString
            item.state = connection.isEnabled ? .on : .off
            item.toolTip = "\(connection.localEndpoint) → \(connection.destinationEndpoint) via \(connection.sshEndpoint)\n\(state.detail)"
            menu.addItem(item)
        }
        if !connections.isEmpty {
            let hint = NSMenuItem(title: "✓ Enabled connections reconnect automatically", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit Ports", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.toolTip = "Ports: \(connected) connected, \(enabled) enabled"
        statusItem.button?.setAccessibilityLabel("Ports: \(connected) connected, \(enabled) enabled")
    }

    @objc private func toggleForwarding(_ sender: NSMenuItem) {
        guard let rawID = sender.representedObject as? String, let id = UUID(uuidString: rawID),
              let forwarding = store.forwardings.first(where: { $0.id == id }) else { return }
        store.setEnabled(!forwarding.isEnabled, id: id)
        if store.errorMessage != nil { showSettings() }
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Ports Settings"
            window.minSize = NSSize(width: 780, height: 540)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("PortsSettings")
            window.contentViewController = NSHostingController(rootView: SettingsView(store: store))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func willSleep() { store.setSleeping(true) }
    @objc private func didWake() { store.setSleeping(false) }

    private func installApplicationMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Ports")
        let settings = NSMenuItem(title: "Ports Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Ports", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Ports", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }
}
