import AppKit
import Combine
import Network
import PortsCore

@MainActor final class AppStore: ObservableObject {
    @Published private(set) var configuration = Configuration()
    @Published private(set) var states: [UUID: TunnelState] = [:]
    @Published var errorMessage: String?
    @Published private(set) var configurationUnavailable = false

    let configurationURL: URL
    private let persistence: ConfigurationStore
    private let supervisor: TunnelSupervisor
    private let monitor = NWPathMonitor()

    var hasRunningSessions: Bool { supervisor.hasRunningSessions }
    var forwardings: [Forwarding] { configuration.forwardings }
    var groups: [ForwardingGroup] { configuration.groups }

    init() {
        configurationURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ports", isDirectory: true).appendingPathComponent("forwardings.json")
        persistence = ConfigurationStore(url: configurationURL)
        let executablePath = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        supervisor = TunnelSupervisor(networkAvailable: false, scheduler: TaskScheduler()) { forwarding in
            let command = try SSHCommand(for: forwarding, askpassExecutable: executablePath)
            return SystemSSHSession(command: command)
        }
        supervisor.onChange = { [weak self] in
            guard let self else { return }
            self.states = self.supervisor.states
        }
        loadConfiguration()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.supervisor.networkChanged(isAvailable: path.status == .satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "app.ports.network"))
    }

    func loadConfiguration() {
        do {
            let loaded = try persistence.load()
            configurationUnavailable = false
            configuration = loaded
            supervisor.apply(loaded.forwardings)
        } catch {
            // Never replace an unreadable configuration with an empty document.
            configurationUnavailable = true
            errorMessage = "Ports could not load \(configurationURL.path).\n\n\(error.localizedDescription)\n\nYour file has been preserved. Fix or move it, then choose Reload Configuration."
        }
    }

    func save(_ forwarding: Forwarding, secret: String?, copyingCredentialsFrom sourceID: UUID? = nil) throws {
        guard !configurationUnavailable else { throw ConfigurationError("Reload the configuration before making changes.") }
        let forwarding = forwarding.normalized()
        try forwarding.validate()
        var secret = secret
        if secret == nil, forwarding.authentication != .agent,
           !forwardings.contains(where: { $0.id == forwarding.id }),
           let source = forwardings.first(where: { $0.id == sourceID }),
           source.authentication == forwarding.authentication {
            secret = try KeychainCredentials.read(id: source.id, kind: forwarding.authentication)
        }
        if forwarding.authentication == .privateKey {
            let path = (forwarding.privateKeyPath as NSString).expandingTildeInPath
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue,
                  FileManager.default.isReadableFile(atPath: path) else {
                throw ConfigurationError("The private key does not exist or cannot be read.")
            }
        }
        if forwarding.authentication == .password,
           (secret == nil || secret?.isEmpty == true),
           !KeychainCredentials.contains(id: forwarding.id, kind: .password) {
            throw ConfigurationError("Enter an SSH password. Ports stores it securely in your login Keychain.")
        }
        var next = forwardings
        var previous = next.first { $0.id == forwarding.id }
        previous?.groupID = forwarding.groupID
        if let index = next.firstIndex(where: { $0.id == forwarding.id }) { next[index] = forwarding }
        else { next.append(forwarding) }
        let nextConfiguration = Configuration(forwardings: next, groups: groups)
        try nextConfiguration.validate()

        // Roll back a credential edit if the configuration cannot be saved.
        var previousSecret: String?
        if let secret, forwarding.authentication != .agent {
            previousSecret = try KeychainCredentials.read(id: forwarding.id, kind: forwarding.authentication)
            try KeychainCredentials.write(secret, id: forwarding.id, kind: forwarding.authentication)
        }
        do { try persistence.save(nextConfiguration) }
        catch {
            if secret != nil, forwarding.authentication != .agent {
                try? KeychainCredentials.write(previousSecret ?? "", id: forwarding.id, kind: forwarding.authentication)
            }
            throw error
        }
        configuration = nextConfiguration
        supervisor.apply(next)
        // Group changes do not restart SSH, but a saved credential change must.
        if secret != nil, forwarding.isEnabled, previous == forwarding { supervisor.reconnect(forwarding.id) }
    }

    func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = forwardings.firstIndex(where: { $0.id == id }), !configurationUnavailable else { return }
        var next = forwardings
        next[index].isEnabled = enabled
        do {
            try commit(Configuration(forwardings: next, groups: groups))
        } catch { errorMessage = error.localizedDescription }
    }

    func saveGroup(_ group: ForwardingGroup) throws {
        guard !configurationUnavailable else { throw ConfigurationError("Reload the configuration before making changes.") }
        var next = configuration
        let group = group.normalized()
        if let index = next.groups.firstIndex(where: { $0.id == group.id }) { next.groups[index] = group }
        else { next.groups.append(group) }
        try commit(next)
    }

    func setGroupEnabled(_ enabled: Bool, id: UUID) {
        guard !configurationUnavailable else { return }
        do { try commit(configuration.settingGroupEnabled(enabled, id: id)) }
        catch { errorMessage = error.localizedDescription }
    }

    func deleteGroup(_ id: UUID) {
        guard !configurationUnavailable else { return }
        do { try commit(configuration.removingGroup(id)) }
        catch { errorMessage = error.localizedDescription }
    }

    func delete(_ id: UUID) {
        guard !configurationUnavailable else { return }
        let next = forwardings.filter { $0.id != id }
        do {
            try commit(Configuration(forwardings: next, groups: groups))
            try KeychainCredentials.delete(id: id)
        } catch { errorMessage = error.localizedDescription }
    }

    private func commit(_ next: Configuration) throws {
        try persistence.save(next)
        configuration = next
        supervisor.apply(next.forwardings)
    }

    func reconnect(_ id: UUID) { supervisor.reconnect(id) }
    func setSleeping(_ value: Bool) { supervisor.setSleeping(value) }
    func shutdown(completion: @escaping @MainActor () -> Void) {
        monitor.cancel()
        supervisor.shutdown(completion: completion)
    }
}
