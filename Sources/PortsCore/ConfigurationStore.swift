import Foundation

public struct ConfigurationStore {
    public let url: URL

    public init(url: URL) { self.url = url }

    private struct Document: Codable {
        var version = 1
        var forwardings: [Forwarding]
    }

    public func load() throws -> [Forwarding] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        guard document.version == 1 else {
            throw ConfigurationError("This configuration was created by a newer version of Ports. Update Ports before editing it.")
        }
        let forwardings = document.forwardings.map { $0.normalized() }
        try Forwarding.validateAll(forwardings)
        return forwardings
    }

    public func save(_ forwardings: [Forwarding]) throws {
        try Forwarding.validateAll(forwardings)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Document(forwardings: forwardings)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
