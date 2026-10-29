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
        XCTAssertEqual(try store.load(), [])
        var forwarding = sampleForwarding()
        forwarding.authentication = .privateKey
        forwarding.privateKeyPath = "~/.ssh/id_ed25519"
        forwarding.hostKeyPolicy = .acceptNew
        try store.save([forwarding])
        XCTAssertEqual(try store.load(), [forwarding])
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

    func testDuplicateCanBeSavedAndEditedWithoutChangingOriginal() throws {
        let store = ConfigurationStore(url: try temporaryURL())
        let original = sampleForwarding()
        var copy = original.duplicated()
        try store.save([original, copy])
        XCTAssertEqual(try store.load(), [original, copy])

        copy.label = "Analytics database"
        copy.localPort += 1
        copy.destinationPort += 1
        copy.isEnabled = true
        try store.save([original, copy])
        XCTAssertEqual(try store.load(), [original, copy])
    }

    func testInvalidSaveDoesNotReplaceExistingConfiguration() throws {
        let url = try temporaryURL()
        let store = ConfigurationStore(url: url)
        let valid = sampleForwarding()
        try store.save([valid])
        var invalid = valid
        invalid.localPort = 0
        XCTAssertThrowsError(try store.save([invalid]))
        XCTAssertEqual(try store.load(), [valid])
    }
}
