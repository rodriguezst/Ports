import Foundation

public struct ConfigurationStore {
    public let url: URL

    public init(url: URL) { self.url = url }

    private struct Document: Codable {
        var version = 2
        var forwardings: [Forwarding]
        var groups: [ForwardingGroup]

        init(_ configuration: Configuration) {
            forwardings = configuration.forwardings
            groups = configuration.groups
        }

        private enum CodingKeys: String, CodingKey { case version, forwardings, groups }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            guard version == 1 || version == 2 else {
                throw ConfigurationError("This configuration was created by a newer version of Ports. Update Ports before editing it.")
            }
            forwardings = try values.decode([Forwarding].self, forKey: .forwardings)
            groups = version == 1 ? [] : try values.decode([ForwardingGroup].self, forKey: .groups)
        }
    }

    public func load() throws -> Configuration {
        guard FileManager.default.fileExists(atPath: url.path) else { return Configuration() }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        let configuration = Configuration(forwardings: document.forwardings.map { $0.normalized() },
                                          groups: document.groups.map { $0.normalized() })
        try configuration.validate()
        return configuration
    }

    public func save(_ configuration: Configuration) throws {
        try configuration.validate()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Document(configuration)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
