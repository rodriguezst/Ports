import AppKit
import PortsCore

/// Keep the displayed menu and forwarding items alive so status changes also
/// reach the menu AppKit is currently tracking.
@MainActor final class ForwardingMenu {
    let menu = NSMenu()
    private let heading = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let empty = NSMenuItem(title: "No port forwardings configured", action: nil, keyEquivalent: "")
    private let hint = NSMenuItem(title: "✓ Enabled connections reconnect automatically", action: nil, keyEquivalent: "")
    private let ungrouped = NSMenuItem(title: "Ungrouped", action: nil, keyEquivalent: "")
    private var items: [UUID: NSMenuItem] = [:]
    private var groupItems: [UUID: NSMenuItem] = [:]
    private weak var target: AnyObject?
    private let toggleAction: Selector
    private let groupToggleAction: Selector

    init(target: AnyObject, toggleAction: Selector, groupToggleAction: Selector,
         settingsAction: Selector, quitAction: Selector) {
        self.target = target
        self.toggleAction = toggleAction
        self.groupToggleAction = groupToggleAction
        menu.autoenablesItems = false
        heading.isEnabled = false
        empty.isEnabled = false
        hint.isEnabled = false
        hint.isHidden = true
        ungrouped.isEnabled = false
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

    func update(connections: [Forwarding], groups: [ForwardingGroup] = [], states: [UUID: TunnelState]) {
        let identifiers = Set(connections.map(\.id))
        for id in Array(items.keys) where !identifiers.contains(id) {
            if let item = items.removeValue(forKey: id) { menu.removeItem(item) }
        }
        let groupIDs = Set(groups.map(\.id))
        for id in Array(groupItems.keys) where !groupIDs.contains(id) {
            if let item = groupItems.removeValue(forKey: id) { menu.removeItem(item) }
        }
        for connection in connections {
            let item: NSMenuItem
            if let existing = items[connection.id] {
                item = existing
            } else {
                item = NSMenuItem(title: "", action: toggleAction, keyEquivalent: "")
                item.target = target
                item.representedObject = connection.id.uuidString
                items[connection.id] = item
            }
            let state = states[connection.id] ?? .disabled
            item.title = "\(connection.label) — \(state.title)"
            item.state = connection.isEnabled ? .on : .off
            item.indentationLevel = connection.groupID == nil ? 0 : 1
            item.toolTip = "\(connection.localEndpoint) → \(connection.destinationEndpoint) via \(connection.sshEndpoint)\n\(state.detail)"
        }
        var ordered: [NSMenuItem] = []
        for group in groups {
            let members = connections.filter { $0.groupID == group.id }
            let enabled = members.filter(\.isEnabled).count
            let connected = members.filter { states[$0.id] == .connected }.count
            let item: NSMenuItem
            if let existing = groupItems[group.id] {
                item = existing
            } else {
                item = NSMenuItem(title: "", action: groupToggleAction, keyEquivalent: "")
                item.target = target
                item.representedObject = group.id.uuidString
                groupItems[group.id] = item
            }
            item.title = "\(group.name) — \(enabled)/\(members.count) enabled · \(connected) connected"
            item.state = enabled == 0 ? .off : (enabled == members.count ? .on : .mixed)
            item.isEnabled = !members.isEmpty
            item.toolTip = enabled == members.count ? "Disable all forwardings in this group" : "Enable all forwardings in this group"
            ordered.append(item)
            ordered.append(contentsOf: members.compactMap { items[$0.id] })
        }
        let ungroupedConnections = connections.filter { $0.groupID == nil }
        if !groups.isEmpty && !ungroupedConnections.isEmpty { ordered.append(ungrouped) }
        else if ungrouped.menu != nil { menu.removeItem(ungrouped) }
        ordered.append(contentsOf: ungroupedConnections.compactMap { items[$0.id] })
        for (index, item) in ordered.enumerated() {
            let position = index + 2
            if menu.index(of: item) != position {
                if item.menu != nil { menu.removeItem(item) }
                menu.insertItem(item, at: position)
            }
        }
        let connected = connections.filter { states[$0.id] == .connected }.count
        heading.title = "Ports · \(connected) connected"
        empty.isHidden = !connections.isEmpty
        hint.isHidden = connections.isEmpty
    }
}
