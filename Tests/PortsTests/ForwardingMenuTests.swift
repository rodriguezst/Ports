import AppKit
import XCTest
import PortsCore
@testable import Ports

@MainActor final class ForwardingMenuTests: XCTestCase {
    private func makeMenu() -> ForwardingMenu {
        _ = NSApplication.shared
        return ForwardingMenu(target: self, toggleAction: #selector(toggle(_:)),
                              groupToggleAction: #selector(toggleGroup(_:)),
                              settingsAction: #selector(settings), quitAction: #selector(quit))
    }

    @objc private func toggle(_ sender: NSMenuItem) {}
    @objc private func toggleGroup(_ sender: NSMenuItem) {}
    @objc private func settings() {}
    @objc private func quit() {}

    func testGroupsShowMixedStateAndKeepGroupAndPortItemsAliveDuringStatusUpdates() async throws {
        let controller = makeMenu()
        var group = ForwardingGroup(name: "Development")
        var first = Forwarding(label: "Database", isEnabled: true, groupID: group.id)
        var second = Forwarding(label: "Web", groupID: group.id)
        let ungrouped = Forwarding(label: "Other")
        controller.update(connections: [first, second, ungrouped], groups: [group], states: [first.id: .connected])
        let groupItem = try XCTUnwrap(controller.menu.item(at: 2))
        let firstItem = try XCTUnwrap(controller.menu.item(at: 3))
        let secondItem = try XCTUnwrap(controller.menu.item(at: 4))
        XCTAssertEqual(groupItem.title, "Development — 1/2 enabled · 1 connected")
        XCTAssertEqual(groupItem.state, .mixed)
        XCTAssertEqual(groupItem.representedObject as? String, group.id.uuidString)
        XCTAssertEqual(groupItem.action, #selector(toggleGroup(_:)))
        XCTAssertTrue(groupItem.target === self)
        XCTAssertEqual(firstItem.indentationLevel, 1)
        XCTAssertEqual(secondItem.indentationLevel, 1)
        XCTAssertEqual(controller.menu.item(at: 5)?.title, "Ungrouped")
        XCTAssertEqual(controller.menu.item(at: 6)?.indentationLevel, 0)

        group.name = "Staging"
        second.isEnabled = true
        controller.update(connections: [first, second, ungrouped], groups: [group], states: [first.id: .connecting])
        XCTAssertTrue(controller.menu.item(at: 2) === groupItem)
        XCTAssertTrue(controller.menu.item(at: 3) === firstItem)
        XCTAssertTrue(controller.menu.item(at: 4) === secondItem)
        XCTAssertEqual(groupItem.title, "Staging — 2/2 enabled · 0 connected")
        XCTAssertEqual(groupItem.state, .on)
        XCTAssertEqual(groupItem.toolTip, "Disable all forwardings in this group")

        first.isEnabled = false
        second.isEnabled = false
        controller.update(connections: [first, second, ungrouped], groups: [group], states: [:])
        XCTAssertEqual(groupItem.state, .off)
        XCTAssertEqual(groupItem.toolTip, "Enable all forwardings in this group")
    }

    func testMovingPortsAndDeletingGroupsPreservesPortActionIdentity() async throws {
        let controller = makeMenu()
        let firstGroup = ForwardingGroup(name: "Development")
        let secondGroup = ForwardingGroup(name: "Production")
        var connection = Forwarding(label: "Database", groupID: firstGroup.id)
        controller.update(connections: [connection], groups: [firstGroup, secondGroup], states: [:])
        let original = try XCTUnwrap(controller.menu.item(at: 3))
        let removedGroup = try XCTUnwrap(controller.menu.item(at: 2))
        let emptyGroup = try XCTUnwrap(controller.menu.item(at: 4))
        XCTAssertFalse(emptyGroup.isEnabled)
        XCTAssertEqual(emptyGroup.state, .off)

        connection.groupID = secondGroup.id
        controller.update(connections: [connection], groups: [secondGroup, firstGroup], states: [:])
        XCTAssertTrue(controller.menu.item(at: 3) === original)
        XCTAssertTrue(emptyGroup.isEnabled)

        connection.groupID = nil
        controller.update(connections: [connection], groups: [], states: [:])
        XCTAssertNil(removedGroup.menu)
        XCTAssertNil(emptyGroup.menu)
        XCTAssertTrue(controller.menu.item(at: 2) === original)
        XCTAssertEqual(original.indentationLevel, 0)
        XCTAssertEqual(original.action, #selector(toggle(_:)))
        XCTAssertEqual(original.representedObject as? String, connection.id.uuidString)
        XCTAssertFalse(controller.menu.items.contains { $0.title == "Ungrouped" })
    }

    func testStatusChangesUpdateTheExistingMenuAndItem() async throws {
        let controller = makeMenu()
        let connection = Forwarding(label: "Database", isEnabled: true)
        controller.update(connections: [connection], states: [connection.id: .connecting])
        let menu = controller.menu
        let item = try XCTUnwrap(menu.item(at: 2))
        XCTAssertEqual(item.title, "Database — Connecting…")
        XCTAssertEqual(item.state, .on)

        controller.update(connections: [connection], states: [connection.id: .connected])
        XCTAssertTrue(controller.menu === menu)
        XCTAssertTrue(menu.item(at: 2) === item)
        XCTAssertEqual(menu.item(at: 0)?.title, "Ports · 1 connected")
        XCTAssertEqual(item.title, "Database — Connected")

        let retry = TunnelState.retrying(seconds: 4, reason: "Network interrupted")
        controller.update(connections: [connection], states: [connection.id: retry])
        XCTAssertTrue(menu.item(at: 2) === item)
        XCTAssertEqual(menu.item(at: 0)?.title, "Ports · 0 connected")
        XCTAssertEqual(item.title, "Database — Retrying in 4s")
        XCTAssertEqual(item.state, .on)
        XCTAssertTrue(item.toolTip?.contains("Network interrupted") == true)
        XCTAssertEqual(item.representedObject as? String, connection.id.uuidString)
        XCTAssertTrue(item.target === self)
        XCTAssertEqual(item.action, #selector(toggle(_:)))
    }

    func testEditsAndDisablingRefreshTheSameItem() async throws {
        let controller = makeMenu()
        var connection = Forwarding(label: "Database", isEnabled: true)
        controller.update(connections: [connection], states: [connection.id: .connected])
        let item = try XCTUnwrap(controller.menu.item(at: 2))

        connection.label = "Analytics"
        connection.localPort = 15432
        connection.destinationPort = 5432
        connection.isEnabled = false
        controller.update(connections: [connection], states: [:])
        XCTAssertTrue(controller.menu.item(at: 2) === item)
        XCTAssertEqual(item.title, "Analytics — Disabled")
        XCTAssertEqual(item.state, .off)
        XCTAssertTrue(item.toolTip?.contains("127.0.0.1:15432 → localhost:5432") == true)
    }

    func testAddingReorderingAndRemovingForwardingsPreservesActionIdentity() async throws {
        let controller = makeMenu()
        let original = Forwarding(label: "Database")
        let copy = original.duplicated()
        controller.update(connections: [original], states: [:])
        let originalItem = try XCTUnwrap(controller.menu.item(at: 2))
        controller.update(connections: [copy, original], states: [:])
        let copyItem = try XCTUnwrap(controller.menu.item(at: 2))
        XCTAssertTrue(controller.menu.item(at: 3) === originalItem)
        XCTAssertEqual(copyItem.representedObject as? String, copy.id.uuidString)

        controller.update(connections: [copy], states: [:])
        XCTAssertNil(originalItem.menu)
        XCTAssertTrue(controller.menu.item(at: 2) === copyItem)
        controller.update(connections: [], states: [:])
        XCTAssertNil(copyItem.menu)
        let visible = controller.menu.items.filter { !$0.isHidden }
        XCTAssertTrue(visible.contains { $0.title == "No port forwardings configured" })
        XCTAssertFalse(visible.contains { $0.representedObject is String })
        XCTAssertFalse(visible.contains { $0.title.contains("reconnect automatically") })
        XCTAssertTrue(visible.contains { $0.title == "Settings…" })
        XCTAssertTrue(visible.contains { $0.title == "Quit Ports" })
    }
}
