import Foundation
import XCTest
@testable import PortsCore

@MainActor final class SystemSSHSessionTests: XCTestCase {
    private func executable(_ script: String, interpreter: String = "/bin/sh") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PortsProcessTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-ssh")
        try Data(("#!\(interpreter)\n" + script).utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    func testProcessOutputIsDrainedInOrderBeforeExit() async throws {
        let executable = try executable("""
        printf 'debug1: Connecting to host\\n' >&2
        printf 'debug1: Entering interactive ' >&2
        printf 'session.\\nConnection closed by remote host.\\n' >&2
        exit 42
        """)
        let command = try SSHCommand(for: sampleForwarding(), askpassExecutable: "/unused")
        let session = SystemSSHSession(command: command, executableURL: executable)
        let exited = expectation(description: "Process exited")
        var events: [SSHEvent] = []
        try session.start { event in
            events.append(event)
            if case .exited = event { exited.fulfill() }
        }
        await fulfillment(of: [exited], timeout: 10)
        XCTAssertEqual(events, [.ready, .diagnostic("Connection closed by remote host."), .exited(42)])
    }

    func testStopEscalatesWhenProcessIgnoresTermination() async throws {
        let executable = try executable("""
        trap '' TERM
        printf 'debug1: Entering interactive session.\\n' >&2
        while :; do sleep 0.1; done
        """)
        let command = try SSHCommand(for: sampleForwarding(), askpassExecutable: "/unused")
        let session = SystemSSHSession(command: command, executableURL: executable)
        let ready = expectation(description: "Process ready")
        let exited = expectation(description: "Process killed")
        var exitCode: Int32?
        try session.start { event in
            if event == .ready { ready.fulfill() }
            if case .exited(let code) = event { exitCode = code; exited.fulfill() }
        }
        await fulfillment(of: [ready], timeout: 10)
        session.stop()
        session.stop()
        await fulfillment(of: [exited], timeout: 10)
        XCTAssertEqual(exitCode, 9)
    }

    func testMissingSSHExecutableThrowsWithoutStartingReader() async throws {
        let command = try SSHCommand(for: sampleForwarding(), askpassExecutable: "/unused")
        let session = SystemSSHSession(command: command, executableURL: URL(fileURLWithPath: "/nonexistent/ports-ssh"))
        XCTAssertThrowsError(try session.start { _ in XCTFail("Unlaunched process emitted an event") })
    }

    func testInheritedPipeDoesNotHideParentExit() async throws {
        let executable = try executable("""
        import subprocess, sys
        print('debug1: Entering interactive session.', file=sys.stderr, flush=True)
        subprocess.Popen(['/bin/sleep', '3'], close_fds=True)
        """, interpreter: "/usr/bin/python3")
        let command = try SSHCommand(for: sampleForwarding(), askpassExecutable: "/unused")
        let session = SystemSSHSession(command: command, executableURL: executable)
        let exited = expectation(description: "Parent exit detected without waiting for child")
        try session.start { event in if case .exited = event { exited.fulfill() } }
        await fulfillment(of: [exited], timeout: 2)
    }
}
