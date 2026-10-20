import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Runs the system OpenSSH client directly, with no shell and no secrets in argv
/// or the environment. A background reader drains stderr for the process lifetime.
@MainActor public final class SystemSSHSession: SSHSession {
    private let process = Process()
    private let command: SSHCommand
    private let executableURL: URL
    private var consumer: Task<Void, Never>?
    private var stopping = false

    public init(command: SSHCommand, executableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh")) {
        self.command = command
        self.executableURL = executableURL
    }

    public func start(onEvent: @escaping @MainActor (SSHEvent) -> Void) throws {
        let pipe = Pipe()
        process.executableURL = executableURL
        process.arguments = command.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = pipe

        var streamContinuation: AsyncStream<SSHEvent>.Continuation!
        let events = AsyncStream<SSHEvent> { streamContinuation = $0 }
        let continuation = streamContinuation!
        do { try process.run() }
        catch {
            pipe.fileHandleForReading.closeFile()
            pipe.fileHandleForWriting.closeFile()
            continuation.finish()
            throw error
        }
        pipe.fileHandleForWriting.closeFile()

        consumer = Task { @MainActor in
            for await event in events {
                onEvent(event)
            }
        }
        let runningProcess = process
        DispatchQueue(label: "app.ports.ssh.\(process.processIdentifier)", qos: .utility).async {
            let reader = pipe.fileHandleForReading
            var pending = Data()
            do {
                var bytes = [UInt8](repeating: 0, count: 4096)
                while true {
                    var descriptor = pollfd(fd: reader.fileDescriptor, events: Int16(POLLIN), revents: 0)
                    let available = poll(&descriptor, 1, 200)
                    if available == 0 {
                        // A helper may inherit stderr. Its lifetime must not delay
                        // noticing that the actual SSH process has already exited.
                        if !runningProcess.isRunning { break }
                        continue
                    }
                    if available < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    let count = bytes.withUnsafeMutableBytes { buffer in
                        read(reader.fileDescriptor, buffer.baseAddress, buffer.count)
                    }
                    if count == 0 { break }
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    pending.append(contentsOf: bytes.prefix(count))
                    while let newline = pending.firstIndex(of: 10) {
                        let line = String(decoding: pending[..<newline], as: UTF8.self)
                        pending.removeSubrange(...newline)
                        if let event = SSHLogParser.event(for: line) { continuation.yield(event) }
                    }
                    // Bound memory even if a server sends an unterminated diagnostic.
                    if pending.count > 16_384 { pending = Data(pending.suffix(4096)) }
                }
                if !pending.isEmpty, let event = SSHLogParser.event(for: String(decoding: pending, as: UTF8.self)) {
                    continuation.yield(event)
                }
            } catch {
                continuation.yield(.diagnostic("Could not read SSH output: \(error.localizedDescription)"))
                Self.terminate(runningProcess)
            }
            runningProcess.waitUntilExit()
            continuation.yield(.exited(runningProcess.terminationStatus))
            continuation.finish()
            try? reader.close()
        }
    }

    public func stop() {
        guard process.isRunning, !stopping else { return }
        stopping = true
        Self.terminate(process)
    }

    private nonisolated static func terminate(_ runningProcess: Process) {
        guard runningProcess.isRunning else { return }
        runningProcess.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if runningProcess.isRunning { kill(runningProcess.processIdentifier, SIGKILL) }
        }
    }
}
