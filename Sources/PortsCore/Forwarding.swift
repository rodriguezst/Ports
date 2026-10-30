import Foundation

public enum Authentication: String, Codable, CaseIterable, Sendable {
    case agent
    case privateKey
    case password

    public var title: String {
        switch self {
        case .agent: return "SSH agent / default keys"
        case .privateKey: return "Private key"
        case .password: return "Password"
        }
    }
}

public enum HostKeyPolicy: String, Codable, CaseIterable, Sendable {
    case strict
    case acceptNew

    public var title: String {
        switch self {
        case .strict: return "Require a known host key"
        case .acceptNew: return "Trust new hosts on first connection"
        }
    }
}

public struct Forwarding: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var label: String
    public var localBindAddress: String
    public var localPort: Int
    public var sshHost: String
    public var sshPort: Int
    public var sshUsername: String
    public var authentication: Authentication
    public var privateKeyPath: String
    public var destinationHost: String
    public var destinationPort: Int
    public var hostKeyPolicy: HostKeyPolicy
    public var isEnabled: Bool
    public var groupID: UUID?

    public init(
        id: UUID = UUID(), label: String = "", localBindAddress: String = "127.0.0.1",
        localPort: Int = 8080, sshHost: String = "", sshPort: Int = 22,
        sshUsername: String = "", authentication: Authentication = .agent,
        privateKeyPath: String = "", destinationHost: String = "localhost",
        destinationPort: Int = 80, hostKeyPolicy: HostKeyPolicy = .strict,
        isEnabled: Bool = false, groupID: UUID? = nil
    ) {
        self.id = id
        self.label = label
        self.localBindAddress = localBindAddress
        self.localPort = localPort
        self.sshHost = sshHost
        self.sshPort = sshPort
        self.sshUsername = sshUsername
        self.authentication = authentication
        self.privateKeyPath = privateKeyPath
        self.destinationHost = destinationHost
        self.destinationPort = destinationPort
        self.hostKeyPolicy = hostKeyPolicy
        self.isEnabled = isEnabled
        self.groupID = groupID
    }

    public var localEndpoint: String { "\(Self.bracketed(localBindAddress)):\(localPort)" }
    public var destinationEndpoint: String { "\(Self.bracketed(destinationHost)):\(destinationPort)" }
    public var sshEndpoint: String { "\(sshUsername)@\(Self.bracketed(sshHost)):\(sshPort)" }

    public func duplicated(existingLabels: Set<String> = []) -> Forwarding {
        var copy = self
        copy.id = UUID()
        copy.isEnabled = false
        var number = 1
        repeat {
            let suffix = number == 1 ? " Copy" : " Copy \(number)"
            copy.label = String(label.prefix(120 - suffix.count)) + suffix
            number += 1
        } while existingLabels.contains(copy.label)
        return copy
    }

    public func normalized() -> Forwarding {
        var value = self
        value.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        value.localBindAddress = Self.unbracketed(localBindAddress.trimmingCharacters(in: .whitespacesAndNewlines))
        value.sshHost = Self.unbracketed(sshHost.trimmingCharacters(in: .whitespacesAndNewlines))
        value.sshUsername = sshUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        value.privateKeyPath = privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        value.destinationHost = Self.unbracketed(destinationHost.trimmingCharacters(in: .whitespacesAndNewlines))
        return value
    }

    public func validate() throws {
        guard !label.isEmpty, label.count <= 120,
              label.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ConfigurationError("Enter a label of 1–120 characters, without line breaks.")
        }
        for (name, port) in [("Local", localPort), ("SSH", sshPort), ("Destination", destinationPort)] {
            guard (1...65535).contains(port) else {
                throw ConfigurationError("\(name) port must be between 1 and 65535.")
            }
        }
        for (name, host) in [("Local bind address", localBindAddress), ("SSH host", sshHost), ("Destination address", destinationHost)] {
            guard Self.validHost(host) else {
                throw ConfigurationError("\(name) must be a hostname or IP address, without a port or spaces.")
            }
        }
        let usernameCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@\\")
        guard !sshUsername.isEmpty, !sshUsername.hasPrefix("-"),
              sshUsername.unicodeScalars.allSatisfy({ usernameCharacters.contains($0) }) else {
            throw ConfigurationError("Enter a valid SSH username without spaces.")
        }
        if authentication == .privateKey {
            guard privateKeyPath.hasPrefix("/") || privateKeyPath.hasPrefix("~/"),
                  privateKeyPath.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw ConfigurationError("Choose a private key using an absolute path or a path starting with ~/.")
            }
        }
    }

    public static func validateAll(_ forwardings: [Forwarding]) throws {
        var identifiers = Set<UUID>()
        for forwarding in forwardings {
            try forwarding.validate()
            guard identifiers.insert(forwarding.id).inserted else {
                throw ConfigurationError("The configuration contains duplicate connection identifiers.")
            }
        }
        let enabled = forwardings.filter(\.isEnabled)
        for (index, first) in enabled.enumerated() {
            for second in enabled.dropFirst(index + 1) where first.localPort == second.localPort {
                if addressesOverlap(first.localBindAddress, second.localBindAddress) {
                    throw ConfigurationError("“\(first.label)” and “\(second.label)” use the same local port and overlapping bind addresses. Disable one or choose another port.")
                }
            }
        }
    }

    public static func bracketed(_ host: String) -> String {
        let host = unbracketed(host)
        return host.contains(":") ? "[\(host)]" : host
    }

    private static func unbracketed(_ host: String) -> String {
        host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
    }

    private static func validHost(_ host: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:%")
        guard !host.isEmpty, !host.hasPrefix("-"), !host.hasPrefix("."),
              host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        // A colon is valid only in an IPv6 address, never as a host:port suffix.
        return !host.contains(":") || host.filter({ $0 == ":" }).count >= 2
    }

    private static func addressesOverlap(_ first: String, _ second: String) -> Bool {
        let first = first.lowercased(), second = second.lowercased()
        if first == second { return true }
        if ["0.0.0.0", "::"].contains(first) || ["0.0.0.0", "::"].contains(second) { return true }
        let loopback = ["localhost", "127.0.0.1", "::1"]
        return (first == "localhost" || second == "localhost") && loopback.contains(first) && loopback.contains(second)
    }
}

public struct ConfigurationError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
