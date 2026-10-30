import Foundation

@MainActor public protocol SSHSession: AnyObject {
    func start(onEvent: @escaping @MainActor (SSHEvent) -> Void) throws
    /// Stop asynchronously; the session must still deliver an exited event.
    func stop()
}

public enum TunnelState: Equatable, Sendable {
    case disabled
    case waitingForNetwork
    case sleeping
    case connecting
    case connected
    case retrying(seconds: Int, reason: String)

    public var title: String {
        switch self {
        case .disabled: return "Disabled"
        case .waitingForNetwork: return "Waiting for network"
        case .sleeping: return "Waiting for wake"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .retrying(let seconds, _): return "Retrying in \(seconds)s"
        }
    }

    public var detail: String {
        switch self {
        case .disabled: return "Enable this forwarding to keep it connected."
        case .waitingForNetwork: return "Ports will reconnect automatically when the network returns."
        case .sleeping: return "Ports will reconnect automatically when your Mac wakes."
        case .connecting: return "Establishing the SSH connection and local listener."
        case .connected: return "The SSH tunnel is ready. Destination services are reached through the remote host."
        case .retrying(_, let reason): return reason
        }
    }
}

/// Desired state is independent of a process's lifetime: enabled connections stay
/// enabled through outages, and disabling cancels every pending reconnect.
@MainActor public final class TunnelSupervisor {
    public typealias SessionFactory = @MainActor (Forwarding) throws -> SSHSession
    public private(set) var states: [UUID: TunnelState] = [:]
    public var onChange: (@MainActor () -> Void)?
    public var hasRunningSessions: Bool { !retiringSessions.isEmpty || runtimes.values.contains { $0.session != nil } }

    @MainActor private final class Runtime {
        var session: SSHSession?
        var generation = UUID()
        var stopRequested = false
        var failures = 0
        var diagnostic: String?
        var retry: Cancellation?
        var deadline: Cancellation?
        var stability: Cancellation?

        func cancelTimers() {
            retry?.cancel(); retry = nil
            deadline?.cancel(); deadline = nil
            stability?.cancel(); stability = nil
        }
    }

    private var connections: [UUID: Forwarding] = [:]
    private var runtimes: [UUID: Runtime] = [:]
    private var retiringSessions: [UUID: SSHSession] = [:]
    private let makeSession: SessionFactory
    private let scheduler: Scheduler
    private var networkAvailable: Bool
    private var sleeping = false
    private var shuttingDown = false
    private var onShutdown: (@MainActor () -> Void)?

    public init(networkAvailable: Bool = true, scheduler: Scheduler, makeSession: @escaping SessionFactory) {
        self.networkAvailable = networkAvailable
        self.scheduler = scheduler
        self.makeSession = makeSession
    }

    public func apply(_ forwardings: [Forwarding]) {
        guard !shuttingDown else { return }
        let previous = connections
        connections = Dictionary(uniqueKeysWithValues: forwardings.map { ($0.id, $0) })
        for id in Array(runtimes.keys) where connections[id] == nil {
            let runtime = runtimes.removeValue(forKey: id)
            runtime?.cancelTimers()
            if let runtime, let session = runtime.session {
                retiringSessions[runtime.generation] = session
                session.stop()
            }
            states.removeValue(forKey: id)
        }
        for connection in forwardings {
            if runtimes[connection.id] == nil { runtimes[connection.id] = Runtime() }
            // Group membership is organizational and does not change the SSH session.
            var previousConnection = previous[connection.id]
            previousConnection?.groupID = connection.groupID
            reconcile(connection.id, restart: previousConnection != connection)
        }
        onChange?()
    }

    /// Also restart healthy sessions when a satisfied path changes (e.g. Wi-Fi to Ethernet).
    public func networkChanged(isAvailable: Bool) {
        guard !shuttingDown else { return }
        networkAvailable = isAvailable
        for id in connections.keys { reconcile(id, restart: true) }
    }

    public func setSleeping(_ value: Bool) {
        guard !shuttingDown else { return }
        sleeping = value
        for id in connections.keys { reconcile(id, restart: true) }
    }

    public func reconnect(_ id: UUID) {
        guard !shuttingDown, let runtime = runtimes[id] else { return }
        runtime.failures = 0
        reconcile(id, restart: true)
    }

    public func shutdown(completion: @escaping @MainActor () -> Void) {
        shuttingDown = true
        onShutdown = completion
        for runtime in runtimes.values {
            runtime.cancelTimers()
            runtime.stopRequested = true
            runtime.session?.stop()
        }
        for session in retiringSessions.values { session.stop() }
        finishShutdownIfNeeded()
    }

    private func reconcile(_ id: UUID, restart: Bool) {
        guard let connection = connections[id], let runtime = runtimes[id] else { return }
        let canRun = connection.isEnabled && networkAvailable && !sleeping
        if !canRun || restart {
            runtime.cancelTimers()
            if runtime.session != nil {
                runtime.stopRequested = true
                runtime.session?.stop()
            }
        }
        guard canRun else {
            if !connection.isEnabled {
                runtime.failures = 0
                setState(.disabled, for: id)
            } else {
                setState(sleeping ? .sleeping : .waitingForNetwork, for: id)
            }
            return
        }
        // Wait for the old process to exit before reusing its local port.
        if runtime.session != nil {
            if runtime.stopRequested { setState(.connecting, for: id) }
        } else if runtime.retry == nil {
            connect(id)
        }
    }

    private func connect(_ id: UUID) {
        guard !shuttingDown, networkAvailable, !sleeping,
              let connection = connections[id], connection.isEnabled,
              let runtime = runtimes[id], runtime.session == nil else { return }
        runtime.retry?.cancel(); runtime.retry = nil
        runtime.stopRequested = false
        runtime.diagnostic = nil
        runtime.generation = UUID()
        let generation = runtime.generation
        setState(.connecting, for: id)
        do {
            let session = try makeSession(connection)
            runtime.session = session
            runtime.deadline = scheduler.schedule(after: 45) { [weak self] in
                guard let self, let current = self.runtimes[id], current.generation == generation,
                      !current.stopRequested else { return }
                current.diagnostic = "The SSH connection did not become ready within 45 seconds."
                current.session?.stop()
            }
            try session.start { [weak self] event in self?.receive(event, id: id, generation: generation) }
        } catch {
            runtime.session = nil
            runtime.cancelTimers()
            scheduleRetry(id, reason: error.localizedDescription)
        }
    }

    private func receive(_ event: SSHEvent, id: UUID, generation: UUID) {
        if case .exited = event, retiringSessions.removeValue(forKey: generation) != nil {
            finishShutdownIfNeeded()
            return
        }
        guard let runtime = runtimes[id], runtime.generation == generation else { return }
        if case .exited(let code) = event {
            runtime.session = nil
            runtime.deadline?.cancel(); runtime.deadline = nil
            runtime.stability?.cancel(); runtime.stability = nil
            if shuttingDown { finishShutdownIfNeeded(); return }
            if runtime.stopRequested {
                runtime.stopRequested = false
                reconcile(id, restart: false)
            } else {
                scheduleRetry(id, reason: runtime.diagnostic ?? "SSH disconnected (exit \(code)). Ports will try again automatically.")
            }
            return
        }
        guard !runtime.stopRequested, !shuttingDown else { return }
        switch event {
        case .ready:
            runtime.deadline?.cancel(); runtime.deadline = nil
            runtime.stability?.cancel()
            runtime.stability = scheduler.schedule(after: 60) { [weak self] in
                guard let current = self?.runtimes[id], current.generation == generation else { return }
                current.failures = 0
            }
            setState(.connected, for: id)
        case .diagnostic(let message): runtime.diagnostic = message
        case .exited: break
        }
    }

    private func scheduleRetry(_ id: UUID, reason: String) {
        guard !shuttingDown, let connection = connections[id], let runtime = runtimes[id] else { return }
        guard connection.isEnabled, networkAvailable, !sleeping else { reconcile(id, restart: false); return }
        let seconds = min(30, 1 << min(runtime.failures, 5))
        runtime.failures = min(runtime.failures + 1, 6)
        runtime.retry = scheduler.schedule(after: TimeInterval(seconds)) { [weak self] in
            guard let self, let current = self.runtimes[id] else { return }
            current.retry = nil
            self.connect(id)
        }
        setState(.retrying(seconds: seconds, reason: reason), for: id)
    }

    private func setState(_ state: TunnelState, for id: UUID) {
        guard states[id] != state else { return }
        states[id] = state
        onChange?()
    }

    private func finishShutdownIfNeeded() {
        guard shuttingDown, !hasRunningSessions else { return }
        let completion = onShutdown
        onShutdown = nil
        completion?()
    }
}
