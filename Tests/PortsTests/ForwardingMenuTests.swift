import AppKit
import XCTest
import PortsCore
@testable import Ports

@MainActor final class ForwardingMenuTests: XCTestCase {
    private func makeMenu() -> ForwardingMenu {
        _ = NSApplication.shared
        return ForwardingMenu(target: self, toggleAction: #selector(toggle(_:)),
                              settingsAction: #selector(settings), quitAction: #selector(quit))
    }

    @objc private func toggle(_ sender: NSMenuItem) {}
    @objc private func settings() {}
    @objc private func quit() {}

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
