import Foundation

public struct SSHCommand {
    public let arguments: [String]
    public let environment: [String: String]

    public init(for forwarding: Forwarding, askpassExecutable: String) throws {
        try forwarding.validate()
        var arguments = [
            "-v", "-N", "-T", "-F", "/dev/null",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=12", "-o", "ConnectionAttempts=1",
            "-o", "ControlMaster=no", "-o", "ControlPath=none",
            "-o", "ForkAfterAuthentication=no", "-o", "PermitLocalCommand=no",
            "-o", "ForwardAgent=no", "-o", "ForwardX11=no",
            "-o", "StrictHostKeyChecking=\(forwarding.hostKeyPolicy == .strict ? "yes" : "accept-new")",
            "-o", "NumberOfPasswordPrompts=1"
        ]
        switch forwarding.authentication {
        case .agent:
            arguments += ["-o", "BatchMode=yes", "-o", "PreferredAuthentications=publickey"]
        case .privateKey:
            arguments += ["-o", "BatchMode=no", "-o", "PreferredAuthentications=publickey",
                          "-o", "IdentitiesOnly=yes", "-i", (forwarding.privateKeyPath as NSString).expandingTildeInPath]
        case .password:
            arguments += ["-o", "BatchMode=no", "-o", "PubkeyAuthentication=no",
                          "-o", "KbdInteractiveAuthentication=no", "-o", "PreferredAuthentications=password"]
        }
        arguments += [
            "-p", String(forwarding.sshPort), "-l", forwarding.sshUsername,
            "-L", "\(forwarding.localEndpoint):\(forwarding.destinationEndpoint)",
            "--", forwarding.sshHost
        ]
        self.arguments = arguments
        environment = [
            "LC_ALL": "C", "SSH_ASKPASS": askpassExecutable, "SSH_ASKPASS_REQUIRE": "force",
            "PORTS_ASKPASS_ID": forwarding.id.uuidString,
            "PORTS_ASKPASS_KIND": forwarding.authentication.rawValue
        ]
    }

    public static func verificationCommand(for forwarding: Forwarding) -> String {
        ["ssh", "-F", "/dev/null", "-p", String(forwarding.sshPort), "-l", forwarding.sshUsername, "--", forwarding.sshHost]
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    }
}

public enum SSHEvent: Equatable, Sendable {
    case ready
    case diagnostic(String)
    case exited(Int32)
}

public enum SSHLogParser {
    public static func event(for line: String) -> SSHEvent? {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // OpenSSH emits this after authentication and local listener setup, also with -N.
        if line.hasPrefix("debug1: Entering interactive session.") { return .ready }
        guard !line.isEmpty, !line.hasPrefix("debug"), !line.hasPrefix("OpenSSH_"),
              !line.hasPrefix("Authenticated to "), !line.hasPrefix("Transferred:") else { return nil }
        return .diagnostic(String(line.prefix(1000)))
    }
}
