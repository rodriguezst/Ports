import Foundation
import XCTest
@testable import PortsCore

final class ConfigurationStoreTests: XCTestCase {
    private func temporaryURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PortsTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("forwardings.json")
    }

    func testRoundTripPreservesEnabledStateAndAllConnectionParameters() throws {
        let url = try temporaryURL()
        let store = ConfigurationStore(url: url)
        XCTAssertEqual(try store.load(), Configuration())
        var forwarding = sampleForwarding()
        forwarding.authentication = .privateKey
        forwarding.privateKeyPath = "~/.ssh/id_ed25519"
        forwarding.hostKeyPolicy = .acceptNew
        try store.save(Configuration(forwardings: [forwarding]))
        XCTAssertEqual(try store.load().forwardings, [forwarding])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(json.contains("passphrase"))
        XCTAssertFalse(json.contains("secret"))
    }

    func testCorruptAndNewerConfigurationIsNotSilentlyDiscarded() throws {
        let url = try temporaryURL()
        let store = ConfigurationStore(url: url)
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        try Data(#"{"version":99,"forwardings":[]}"#.utf8).write(to: url)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertTrue(error.localizedDescription.contains("newer version"))
        }
    }

    func testVersionOneLoadsUngroupedAndIsUpgradedOnSave() throws {
        let url = try temporaryURL()
        let store = ConfigurationStore(url: url)
        let forwarding = sampleForwarding()
        let encoded = try JSONEncoder().encode([forwarding])
        var legacy = Data(#"{"version":1,"forwardings":"#.utf8)
        legacy.append(encoded)
        legacy.append(Data("}".utf8))
        try legacy.write(to: url)

        let loaded = try store.load()
        XCTAssertEqual(loaded.forwardings, [forwarding])
        XCTAssertNil(loaded.forwardings[0].groupID)
        XCTAssertTrue(loaded.groups.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), legacy)
        try store.save(loaded)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(saved["version"] as? Int, 2)
        XCTAssertEqual(try store.load(), loaded)
    }

    func testGroupsMembershipAndMixedEnabledChoicesSurviveReload() throws {
        let store = ConfigurationStore(url: try temporaryURL())
        let group = ForwardingGroup(name: "Development")
        let empty = ForwardingGroup(name: "Production")
        var first = sampleForwarding()
        first.groupID = group.id
        let copy = first.duplicated()
        XCTAssertEqual(copy.groupID, group.id)
        let configuration = Configuration(forwardings: [first, copy], groups: [group, empty])
        try store.save(configuration)
        XCTAssertEqual(try store.load(), configuration)
        XCTAssertEqual(try store.load().enabledState(of: group.id), .mixed)
        try store.save(configuration.settingGroupEnabled(false, id: group.id))
        XCTAssertEqual(try store.load().enabledState(of: group.id), .disabled)
    }

    func testInvalidGroupSaveAndConflictingGroupEnablePreserveSavedFile() throws {
        let url = try temporaryURL()
        let store = ConfigurationStore(url: url)
        let group = ForwardingGroup(name: "Development")
        var forwarding = sampleForwarding(enabled: false)
        forwarding.groupID = group.id
        let configuration = Configuration(forwardings: [forwarding, forwarding.duplicated()], groups: [group])
        try store.save(configuration)
        let original = try Data(contentsOf: url)
        XCTAssertThrowsError(try store.save(configuration.settingGroupEnabled(true, id: group.id)))
        XCTAssertThrowsError(try store.save(Configuration(forwardings: configuration.forwardings)))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testMalformedVersionTwoGroupsAreNotSilentlyDiscarded() throws {
        let url = try temporaryURL()
        let store = ConfigurationStore(url: url)
        for json in [#"{"version":2,"forwardings":[]}"#,
                     #"{"version":2,"forwardings":[],"groups":null}"#] {
            let data = Data(json.utf8)
            try data.write(to: url)
            XCTAssertThrowsError(try store.load())
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testDuplicateCanBeSavedAndEditedWithoutChangingOriginal() throws {
        let store = ConfigurationStore(url: try temporaryURL())
        let original = sampleForwarding()
        var copy = original.duplicated()
        try store.save(Configuration(forwardings: [original, copy]))
        XCTAssertEqual(try store.load().forwardings, [original, copy])

        copy.label = "Analytics database"
        copy.localPort += 1
        copy.destinationPort += 1
        copy.isEnabled = true
        try store.save(Configuration(forwardings: [original, copy]))
        XCTAssertEqual(try store.load().forwardings, [original, copy])
    }

    func testInvalidSaveDoesNotReplaceExistingConfiguration() throws {
        let url = try temporaryURL()
        let store = ConfigurationStore(url: url)
        let valid = sampleForwarding()
        try store.save(Configuration(forwardings: [valid]))
        var invalid = valid
        invalid.localPort = 0
        XCTAssertThrowsError(try store.save(Configuration(forwardings: [invalid])))
        XCTAssertEqual(try store.load().forwardings, [valid])
    }
}
