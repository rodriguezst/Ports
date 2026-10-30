import Foundation
import XCTest
@testable import PortsCore

final class ConfigurationTransferTests: XCTestCase {
    private func groupedConfiguration() -> Configuration {
        let development = ForwardingGroup(name: "Development")
        let production = ForwardingGroup(name: "Production")
        var database = sampleForwarding()
        database.groupID = development.id
        var web = sampleForwarding(enabled: false)
        web.label = "Web"
        web.localPort = 8080
        web.destinationPort = 80
        web.groupID = production.id
        var ungrouped = sampleForwarding(enabled: false)
        ungrouped.label = "Ungrouped database"
        return Configuration(forwardings: [database, web, ungrouped], groups: [development, production])
    }

    func testSelectingOneTunnelIncludesOnlyItsGroupAndPreservesAllSettings() throws {
        let configuration = groupedConfiguration()
        let forwarding = configuration.forwardings[0]
        let selected = try configuration.selectingForwardings([forwarding.id])
        XCTAssertEqual(selected.forwardings, [forwarding])
        XCTAssertEqual(selected.groups, [configuration.groups[0]])
        XCTAssertEqual(configuration.forwardings.count, 3)
        XCTAssertEqual(configuration.groups.count, 2)
    }

    func testSelectingMultipleTunnelsPreservesOrderAndUngroupedMembership() throws {
        let configuration = groupedConfiguration()
        let selected = try configuration.selectingForwardings(Set(configuration.forwardings.suffix(2).map(\.id)))
        XCTAssertEqual(selected.forwardings, Array(configuration.forwardings.suffix(2)))
        XCTAssertEqual(selected.groups, [configuration.groups[1]])
        XCTAssertNil(selected.forwardings[1].groupID)
        let all = try configuration.selectingForwardings(Set(configuration.forwardings.map(\.id)))
        XCTAssertEqual(all, configuration)
    }

    func testEmptyOrMissingSelectionCannotBeExportedOrImported() throws {
        let source = groupedConfiguration()
        for identifiers in [Set<UUID>(), Set([UUID()])] {
            XCTAssertThrowsError(try source.selectingForwardings(identifiers))
            XCTAssertThrowsError(try Configuration().importingForwardings(from: source, selecting: identifiers))
        }
    }

    func testImportAllAuthenticationModesPreservesSettingsWithNewDisabledIdentities() throws {
        var source = Configuration()
        for (index, authentication) in Authentication.allCases.enumerated() {
            var forwarding = sampleForwarding()
            forwarding.label = authentication.title
            forwarding.localPort += index
            forwarding.authentication = authentication
            forwarding.privateKeyPath = "~/.ssh/development"
            forwarding.hostKeyPolicy = .acceptNew
            source.forwardings.append(forwarding)
        }
        let imported = try Configuration().importingForwardings(from: source, selecting: Set(source.forwardings.map(\.id)))
        XCTAssertEqual(imported.forwardings.count, source.forwardings.count)
        let sourceIDs = Set(source.forwardings.map(\.id))
        let importedIDs = Set(imported.forwardings.map(\.id))
        XCTAssertTrue(sourceIDs.isDisjoint(with: importedIDs))
        XCTAssertEqual(importedIDs.count, imported.forwardings.count)
        for (original, copy) in zip(source.forwardings, imported.forwardings) {
            var expected = original
            expected.id = copy.id
            expected.isEnabled = false
            XCTAssertEqual(copy, expected)
        }
        XCTAssertTrue(source.forwardings.allSatisfy(\.isEnabled))
    }

    func testSelectiveImportKeepsExistingEnabledTunnelsAndOnlyAddsNeededGroups() throws {
        let source = groupedConfiguration()
        let existing = sampleForwarding()
        let destination = Configuration(forwardings: [existing])
        let next = try destination.importingForwardings(from: source, selecting: [source.forwardings[0].id])
        XCTAssertEqual(next.forwardings.count, 2)
        XCTAssertEqual(next.forwardings[0], existing)
        XCTAssertEqual(next.forwardings[1].label, "Database (Imported)")
        XCTAssertFalse(next.forwardings[1].isEnabled)
        XCTAssertEqual(next.forwardings[1].groupID, source.groups[0].id)
        XCTAssertEqual(next.groups, [source.groups[0]])
        XCTAssertEqual(destination, Configuration(forwardings: [existing]))
    }

    func testRepeatedImportDoesNotOverwriteTunnelsOrDuplicateMatchingGroups() throws {
        let source = groupedConfiguration()
        let original = source.forwardings[0]
        let once = try source.importingForwardings(from: source, selecting: [original.id])
        let twice = try once.importingForwardings(from: source, selecting: [original.id])
        XCTAssertEqual(Array(twice.forwardings.prefix(3)), source.forwardings)
        XCTAssertEqual(twice.forwardings[3].label, "Database (Imported)")
        XCTAssertEqual(twice.forwardings[4].label, "Database (Imported 2)")
        XCTAssertNotEqual(twice.forwardings[3].id, twice.forwardings[4].id)
        XCTAssertEqual(twice.forwardings[3].groupID, original.groupID)
        XCTAssertEqual(twice.forwardings[4].groupID, original.groupID)
        XCTAssertEqual(twice.groups, source.groups)
    }

    func testConflictingGroupIdentityIsRemappedWithoutChangingExistingGroup() throws {
        let source = groupedConfiguration()
        let sourceGroup = source.groups[0]
        let renamed = ForwardingGroup(id: sourceGroup.id, name: "Renamed locally")
        let sameName = ForwardingGroup(name: sourceGroup.name)
        let destination = Configuration(groups: [renamed, sameName])
        let next = try destination.importingForwardings(from: source, selecting: [source.forwardings[0].id])
        XCTAssertEqual(Array(next.groups.prefix(2)), destination.groups)
        let importedGroup = try XCTUnwrap(next.groups.last)
        XCTAssertNotEqual(importedGroup.id, sourceGroup.id)
        XCTAssertNotEqual(importedGroup.id, sameName.id)
        XCTAssertEqual(importedGroup.name, "Development (Imported)")
        XCTAssertEqual(next.forwardings[0].groupID, importedGroup.id)
    }

    func testImportRenamesLongDuplicateNamesWithinValidationLimits() throws {
        let name = String(repeating: "é", count: 120)
        let group = ForwardingGroup(name: name)
        var forwarding = sampleForwarding()
        forwarding.label = name
        forwarding.groupID = group.id
        let source = Configuration(forwardings: [forwarding], groups: [group])
        let destination = Configuration(forwardings: [forwarding], groups: [ForwardingGroup(id: group.id, name: "Existing"), ForwardingGroup(name: name)])
        let next = try destination.importingForwardings(from: source, selecting: [forwarding.id])
        XCTAssertEqual(next.forwardings[1].label.count, 120)
        XCTAssertTrue(next.forwardings[1].label.hasSuffix(" (Imported)"))
        XCTAssertEqual(next.groups[2].name.count, 120)
        XCTAssertNoThrow(try next.validate())
    }

    func testExportedFileCanBeLoadedAndSelectivelyImportedWithoutCredentialData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PortsTransfer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(url: directory.appendingPathComponent("tunnels.json"))
        var source = groupedConfiguration()
        source.forwardings[0].authentication = .password
        let selection = Set(source.forwardings.prefix(2).map(\.id))
        try store.save(source.selectingForwardings(selection))
        let loaded = try store.load()
        XCTAssertEqual(loaded.forwardings.count, 2)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any])
        let tunnels = try XCTUnwrap(json["forwardings"] as? [[String: Any]])
        for tunnel in tunnels {
            XCTAssertNil(tunnel["password"])
            XCTAssertNil(tunnel["passphrase"])
            XCTAssertNil(tunnel["secret"])
        }
        let imported = try Configuration().importingForwardings(from: loaded, selecting: [loaded.forwardings[1].id])
        XCTAssertEqual(imported.forwardings.count, 1)
        XCTAssertEqual(imported.forwardings[0].label, "Web")
        XCTAssertEqual(imported.groups, [source.groups[1]])
        XCTAssertFalse(imported.forwardings[0].isEnabled)
    }

    func testInvalidImportDoesNotReplaceSavedConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PortsTransfer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(url: directory.appendingPathComponent("tunnels.json"))
        let existing = groupedConfiguration()
        try store.save(existing)
        let before = try Data(contentsOf: store.url)
        var invalid = sampleForwarding()
        invalid.destinationPort = 0
        let source = Configuration(forwardings: [invalid])
        XCTAssertThrowsError(try store.save(existing.importingForwardings(from: source, selecting: [invalid.id])))
        XCTAssertEqual(try Data(contentsOf: store.url), before)
        XCTAssertEqual(try store.load(), existing)
    }
}
