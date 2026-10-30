import Foundation

public struct ForwardingGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String = "") {
        self.id = id
        self.name = name
    }

    public func normalized() -> ForwardingGroup {
        ForwardingGroup(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func validate() throws {
        guard !name.isEmpty, name.count <= 120,
              name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ConfigurationError("Enter a group name of 1–120 characters, without line breaks.")
        }
    }
}

public enum GroupEnabledState: Equatable, Sendable {
    case disabled, mixed, enabled
}

public struct Configuration: Equatable, Sendable {
    public var forwardings: [Forwarding]
    public var groups: [ForwardingGroup]

    public init(forwardings: [Forwarding] = [], groups: [ForwardingGroup] = []) {
        self.forwardings = forwardings
        self.groups = groups
    }

    public func members(of groupID: UUID?) -> [Forwarding] {
        forwardings.filter { $0.groupID == groupID }
    }

    public func enabledState(of groupID: UUID) -> GroupEnabledState {
        let members = members(of: groupID)
        let enabled = members.filter(\.isEnabled).count
        if enabled == 0 { return .disabled }
        return enabled == members.count ? .enabled : .mixed
    }

    /// Validate the entire proposed change before saving or starting any tunnel.
    public func settingGroupEnabled(_ enabled: Bool, id: UUID) throws -> Configuration {
        guard groups.contains(where: { $0.id == id }) else {
            throw ConfigurationError("This group no longer exists.")
        }
        var next = self
        for index in next.forwardings.indices where next.forwardings[index].groupID == id {
            next.forwardings[index].isEnabled = enabled
        }
        try next.validate()
        return next
    }

    /// Removing a group keeps its forwardings and their enabled choices.
    public func removingGroup(_ id: UUID) -> Configuration {
        var next = self
        next.groups.removeAll { $0.id == id }
        for index in next.forwardings.indices where next.forwardings[index].groupID == id {
            next.forwardings[index].groupID = nil
        }
        return next
    }

    public func validate() throws {
        try Forwarding.validateAll(forwardings)
        var identifiers = Set<UUID>()
        for group in groups {
            try group.validate()
            guard identifiers.insert(group.id).inserted else {
                throw ConfigurationError("The configuration contains duplicate group identifiers.")
            }
        }
        for forwarding in forwardings {
            if let groupID = forwarding.groupID, !identifiers.contains(groupID) {
                throw ConfigurationError("“\(forwarding.label)” belongs to a group that does not exist.")
            }
        }
    }
}
