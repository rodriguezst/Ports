import AppKit
import PortsCore

/// Keep the displayed menu and forwarding items alive so status changes also
/// reach the menu AppKit is currently tracking.
@MainActor final class ForwardingMenu {
    let menu = NSMenu()
    private let heading = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let empty = NSMenuItem(title: "No port forwardings configured", action: nil, keyEquivalent: "")
    private let hint = NSMenuItem(title: "✓ Enabled connections reconnect automatically", action: nil, keyEquivalent: "")
    private var items: [UUID: NSMenuItem] = [:]
    private weak var target: AnyObject?
    private let toggleAction: Selector

    init(target: AnyObject, toggleAction: Selector, settingsAction: Selector, quitAction: Selector) {
        self.target = target
        self.toggleAction = toggleAction
        menu.autoenablesItems = false
        heading.isEnabled = false
        empty.isEnabled = false
        hint.isEnabled = false
        hint.isHidden = true
        menu.addItem(heading)
        menu.addItem(.separator())
        menu.addItem(empty)
        menu.addItem(hint)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: settingsAction, keyEquivalent: ",")
        settings.target = target
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit Ports", action: quitAction, keyEquivalent: "q")
        quit.target = target
        menu.addItem(quit)
    }

    func update(connections: [Forwarding], states: [UUID: TunnelState]) {
        let identifiers = Set(connections.map(\.id))
        for id in Array(items.keys) where !identifiers.contains(id) {
            if let item = items.removeValue(forKey: id) { menu.removeItem(item) }
        }
        for (index, connection) in connections.enumerated() {
            let item: NSMenuItem
            if let existing = items[connection.id] {
                item = existing
            } else {
                item = NSMenuItem(title: "", action: toggleAction, keyEquivalent: "")
                item.target = target
                item.representedObject = connection.id.uuidString
                items[connection.id] = item
            }
            let position = index + 2
            if menu.index(of: item) != position {
                if item.menu != nil { menu.removeItem(item) }
                menu.insertItem(item, at: position)
            }
            let state = states[connection.id] ?? .disabled
            item.title = "\(connection.label) — \(state.title)"
            item.state = connection.isEnabled ? .on : .off
            item.toolTip = "\(connection.localEndpoint) → \(connection.destinationEndpoint) via \(connection.sshEndpoint)\n\(state.detail)"
        }
        let connected = connections.filter { states[$0.id] == .connected }.count
        heading.title = "Ports · \(connected) connected"
        empty.isHidden = !connections.isEmpty
        hint.isHidden = connections.isEmpty
    }
}
