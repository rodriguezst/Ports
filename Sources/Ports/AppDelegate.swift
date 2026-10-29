import AppKit
import Combine
import SwiftUI
import PortsCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var store: AppStore!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var observation: AnyCancellable?
    private var forwardingMenu: ForwardingMenu!

    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationMenu()
        store = AppStore()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "Ports"
        if let image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "Ports") {
            image.isTemplate = true
            statusItem.button?.image = image
        } else { statusItem.button?.title = "P" }
        forwardingMenu = ForwardingMenu(target: self, toggleAction: #selector(toggleForwarding(_:)),
                                        settingsAction: #selector(showSettings), quitAction: #selector(quit))
        forwardingMenu.menu.delegate = self
        statusItem.menu = forwardingMenu.menu
        observation = store.$forwardings.combineLatest(store.$states).sink { [weak self] connections, states in
            // Menu tracking uses its own run loop mode. Deliver updates there
            // as well as during the normal application run loop.
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                MainActor.assumeIsolated {
                    self?.updateMenu(connections: connections, states: states)
                }
            }
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
        forwardingMenu.update(connections: connections, states: states)
        let connected = connections.filter { states[$0.id] == .connected }.count
        let enabled = connections.filter(\.isEnabled).count
        statusItem.button?.toolTip = "Ports: \(connected) connected, \(enabled) enabled"
        statusItem.button?.setAccessibilityLabel("Ports: \(connected) connected, \(enabled) enabled")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateMenu(connections: store.forwardings, states: store.states)
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
