import Foundation
import XCTest
@testable import PortsCore

final class ConfigurationTests: XCTestCase {
    func testGroupToggleChangesEveryMemberAndLeavesOtherForwardingsAlone() throws {
        let group = ForwardingGroup(name: "Development")
        let other = ForwardingGroup(name: "Production")
        var first = sampleForwarding(enabled: false)
        first.groupID = group.id
        var second = first.duplicated()
        second.localPort += 1
        second.isEnabled = true
        var unrelated = sampleForwarding()
        unrelated.groupID = other.id
        unrelated.localPort += 2
        var ungrouped = sampleForwarding()
        ungrouped.localPort += 3
        let configuration = Configuration(forwardings: [first, second, unrelated, ungrouped], groups: [group, other])
        XCTAssertEqual(configuration.enabledState(of: group.id), .mixed)

        let enabled = try configuration.settingGroupEnabled(true, id: group.id)
        XCTAssertEqual(enabled.enabledState(of: group.id), .enabled)
        XCTAssertTrue(enabled.members(of: group.id).allSatisfy(\.isEnabled))
        XCTAssertEqual(Array(enabled.forwardings.suffix(2)), [unrelated, ungrouped])
        XCTAssertFalse(configuration.forwardings[0].isEnabled)

        let disabled = try enabled.settingGroupEnabled(false, id: group.id)
        XCTAssertEqual(disabled.enabledState(of: group.id), .disabled)
        XCTAssertTrue(disabled.members(of: group.id).allSatisfy { !$0.isEnabled })
        XCTAssertEqual(Array(disabled.forwardings.suffix(2)), [unrelated, ungrouped])
    }

    func testGroupEnableRejectsConflictsWithinGroupAndWithOtherGroups() throws {
        let group = ForwardingGroup(name: "Development")
        let other = ForwardingGroup(name: "Production")
        var first = sampleForwarding(enabled: false)
        first.groupID = group.id
        var conflicting = first.duplicated()
        var configuration = Configuration(forwardings: [first, conflicting], groups: [group, other])
        XCTAssertThrowsError(try configuration.settingGroupEnabled(true, id: group.id))
        XCTAssertTrue(configuration.forwardings.allSatisfy { !$0.isEnabled })

        conflicting.groupID = other.id
        conflicting.isEnabled = true
        configuration.forwardings[1] = conflicting
        XCTAssertThrowsError(try configuration.settingGroupEnabled(true, id: group.id))
        XCTAssertEqual(configuration.forwardings, [first, conflicting])
    }

    func testEmptyGroupIsDisabledAndMissingGroupCannotBeToggled() throws {
        let group = ForwardingGroup(name: "Empty")
        let configuration = Configuration(groups: [group])
        XCTAssertEqual(configuration.enabledState(of: group.id), .disabled)
        XCTAssertEqual(try configuration.settingGroupEnabled(true, id: group.id), configuration)
        XCTAssertThrowsError(try configuration.settingGroupEnabled(true, id: UUID()))
    }

    func testRemovingGroupPreservesMemberIdentityParametersAndEnabledChoices() throws {
        let group = ForwardingGroup(name: "Development")
        let other = ForwardingGroup(name: "Production")
        var first = sampleForwarding()
        first.groupID = group.id
        var second = first.duplicated()
        var unrelated = sampleForwarding(enabled: false)
        unrelated.groupID = other.id
        let configuration = Configuration(forwardings: [first, second, unrelated], groups: [group, other])
        let next = configuration.removingGroup(group.id)
        first.groupID = nil
        second.groupID = nil
        XCTAssertEqual(next.groups, [other])
        XCTAssertEqual(next.forwardings, [first, second, unrelated])
        XCTAssertNoThrow(try next.validate())
    }

    func testInvalidNamesDuplicateGroupIDsAndDanglingMembershipAreRejected() {
        for name in ["", "bad\nname", String(repeating: "x", count: 121)] {
            XCTAssertThrowsError(try ForwardingGroup(name: name).validate())
        }
        let group = ForwardingGroup(name: "Development")
        XCTAssertThrowsError(try Configuration(groups: [group, group]).validate())
        var forwarding = sampleForwarding()
        forwarding.groupID = group.id
        XCTAssertThrowsError(try Configuration(forwardings: [forwarding]).validate())
        XCTAssertNoThrow(try Configuration(forwardings: [forwarding], groups: [group]).validate())
        XCTAssertEqual(ForwardingGroup(name: "  Development \n").normalized().name, "Development")
    }
}
