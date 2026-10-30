import Foundation
import XCTest
@testable import PortsCore

func sampleForwarding(enabled: Bool = true) -> Forwarding {
    Forwarding(label: "Database", localPort: 15432, sshHost: "bastion.example.com",
               sshUsername: "deploy", destinationHost: "db.internal", destinationPort: 5432, isEnabled: enabled)
}

final class ForwardingTests: XCTestCase {
    func testDuplicatePreservesConnectionSettingsWithIndependentDisabledIdentity() throws {
        for authentication in Authentication.allCases {
            var original = sampleForwarding()
            original.authentication = authentication
            original.privateKeyPath = "~/.ssh/development"
            original.sshPort = 2222
            original.localBindAddress = "::1"
            original.hostKeyPolicy = .acceptNew
            original.groupID = UUID()
            let copy = original.duplicated()

            XCTAssertNotEqual(copy.id, original.id)
            XCTAssertNotEqual(copy.id, original.duplicated().id)
            XCTAssertEqual(copy.label, "Database Copy")
            XCTAssertFalse(copy.isEnabled)
            XCTAssertTrue(original.isEnabled)
            XCTAssertEqual(original.label, "Database")
            var expected = original
            expected.id = copy.id
            expected.label = copy.label
            expected.isEnabled = false
            XCTAssertEqual(copy, expected)
            XCTAssertNoThrow(try Forwarding.validateAll([original, copy]))
        }
    }

    func testDuplicateSuggestsAnUnusedNameWithinLabelLengthLimit() throws {
        let original = sampleForwarding(enabled: false)
        let copy = original.duplicated(existingLabels: ["Database", "Database Copy", "Database Copy 2"])
        XCTAssertEqual(copy.label, "Database Copy 3")

        var longName = original
        longName.label = String(repeating: "é", count: 120)
        let first = longName.duplicated()
        let second = longName.duplicated(existingLabels: [first.label])
        XCTAssertEqual(first.label.count, 120)
        XCTAssertEqual(second.label.count, 120)
        XCTAssertTrue(second.label.hasSuffix(" Copy 2"))
        XCTAssertNoThrow(try first.validate())
        XCTAssertNoThrow(try second.validate())
    }

    func testNormalizationAndIPv6ForwardingArguments() throws {
        var forwarding = sampleForwarding()
        forwarding.label = "  Database  "
        forwarding.localBindAddress = " [::1] "
        forwarding.destinationHost = "[2001:db8::10]"
        forwarding.sshHost = "[2001:db8::1]"
        forwarding = forwarding.normalized()
        try forwarding.validate()
        XCTAssertEqual(forwarding.label, "Database")
        let command = try SSHCommand(for: forwarding, askpassExecutable: "/Applications/Ports.app/Contents/MacOS/Ports")
        let index = try XCTUnwrap(command.arguments.firstIndex(of: "-L"))
        XCTAssertEqual(command.arguments[index + 1], "[::1]:15432:[2001:db8::10]:5432")
        XCTAssertEqual(command.arguments.last, "2001:db8::1")
    }

    func testRejectsInvalidPortsHostsAndOptionInjection() {
        for port in [-1, 0, 65536] {
            var forwarding = sampleForwarding()
            forwarding.localPort = port
            XCTAssertThrowsError(try forwarding.validate())
        }
        for host in ["", "-oProxyCommand=evil", "host;echo bad", "user@host", "host:22", "ssh://host", "host\nname"] {
            var forwarding = sampleForwarding()
            forwarding.sshHost = host
            XCTAssertThrowsError(try forwarding.validate(), host)
        }
        var forwarding = sampleForwarding()
        forwarding.sshUsername = "-bad"
        XCTAssertThrowsError(try forwarding.validate())
    }

    func testAuthenticationModesNeverPutSecretsInCommand() throws {
        var forwarding = sampleForwarding()
        forwarding.authentication = .privateKey
        forwarding.privateKeyPath = "/Users/test/SSH Keys/private key"
        let command = try SSHCommand(for: forwarding, askpassExecutable: "/Applications/Ports.app/Contents/MacOS/Ports")
        XCTAssertTrue(command.arguments.contains(forwarding.privateKeyPath))
        XCTAssertTrue(command.arguments.contains("IdentitiesOnly=yes"))
        XCTAssertEqual(command.environment["PORTS_ASKPASS_ID"], forwarding.id.uuidString)
        XCTAssertEqual(command.environment["PORTS_ASKPASS_KIND"], "privateKey")
        XCTAssertEqual(Set(command.environment.keys), ["PORTS_ASKPASS_ID", "PORTS_ASKPASS_KIND", "LC_ALL", "SSH_ASKPASS", "SSH_ASKPASS_REQUIRE"])

        forwarding.authentication = .password
        let passwordCommand = try SSHCommand(for: forwarding, askpassExecutable: "/Ports")
        XCTAssertTrue(passwordCommand.arguments.contains("PreferredAuthentications=password"))
        XCTAssertTrue(passwordCommand.arguments.contains("PubkeyAuthentication=no"))
        XCTAssertTrue(passwordCommand.arguments.contains("KbdInteractiveAuthentication=no"))
        XCTAssertFalse(passwordCommand.arguments.contains("-i"))

        forwarding.authentication = .agent
        let agentCommand = try SSHCommand(for: forwarding, askpassExecutable: "/Ports")
        XCTAssertTrue(agentCommand.arguments.contains("BatchMode=yes"))
        XCTAssertTrue(agentCommand.arguments.contains("ExitOnForwardFailure=yes"))
        XCTAssertTrue(agentCommand.arguments.contains("ServerAliveInterval=15"))
        XCTAssertTrue(agentCommand.arguments.contains("ServerAliveCountMax=3"))
        XCTAssertTrue(agentCommand.arguments.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(agentCommand.arguments.contains("/dev/null"))
    }

    func testTrustOnFirstUseStillRejectsChangedKeys() throws {
        var forwarding = sampleForwarding()
        forwarding.hostKeyPolicy = .acceptNew
        let command = try SSHCommand(for: forwarding, askpassExecutable: "/Ports")
        XCTAssertTrue(command.arguments.contains("StrictHostKeyChecking=accept-new"))
        XCTAssertFalse(command.arguments.contains("StrictHostKeyChecking=no"))
    }

    func testOverlappingEnabledListenersRejectedButDisabledDuplicatesAllowed() throws {
        let first = sampleForwarding()
        var second = sampleForwarding()
        second.localBindAddress = "0.0.0.0"
        XCTAssertThrowsError(try Forwarding.validateAll([first, second]))
        second.isEnabled = false
        XCTAssertNoThrow(try Forwarding.validateAll([first, second]))
        second.isEnabled = true
        second.localPort += 1
        XCTAssertNoThrow(try Forwarding.validateAll([first, second]))
    }

    func testDuplicateIdentifiersRejected() {
        let forwarding = sampleForwarding(enabled: false)
        XCTAssertThrowsError(try Forwarding.validateAll([forwarding, forwarding]))
    }

    func testLogParserWaitsForEstablishedSession() {
        XCTAssertNil(SSHLogParser.event(for: "debug1: Connecting to bastion..."))
        XCTAssertNil(SSHLogParser.event(for: "debug1: Local forwarding listening on 127.0.0.1 port 15432."))
        XCTAssertEqual(SSHLogParser.event(for: "debug1: Entering interactive session.\r\n"), .ready)
        XCTAssertEqual(SSHLogParser.event(for: "Host key verification failed."), .diagnostic("Host key verification failed."))
        XCTAssertEqual(SSHLogParser.event(for: "deploy@bastion: Permission denied (publickey)."),
                       .diagnostic("deploy@bastion: Permission denied (publickey)."))
    }
}
