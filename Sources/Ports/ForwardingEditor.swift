import AppKit
import SwiftUI
import PortsCore

@MainActor struct ForwardingEditor: View {
    @ObservedObject var store: AppStore
    let isNew: Bool
    let credentialSource: Forwarding?
    let onSave: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var forwarding: Forwarding
    @State private var localPort: String
    @State private var sshPort: String
    @State private var destinationPort: String
    @State private var secret = ""
    @State private var removePassphrase = false
    @State private var errorMessage: String?
    @State private var copied = false

    init(store: AppStore, forwarding: Forwarding, isNew: Bool, credentialSource: Forwarding? = nil,
         onSave: @escaping (UUID) -> Void) {
        self.store = store
        self.isNew = isNew
        self.credentialSource = credentialSource
        self.onSave = onSave
        _forwarding = State(initialValue: forwarding)
        _localPort = State(initialValue: String(forwarding.localPort))
        _sshPort = State(initialValue: String(forwarding.sshPort))
        _destinationPort = State(initialValue: String(forwarding.destinationPort))
    }

    private var hasSavedSecret: Bool {
        if KeychainCredentials.contains(id: forwarding.id, kind: forwarding.authentication) { return true }
        guard let credentialSource, credentialSource.authentication == forwarding.authentication else { return false }
        return KeychainCredentials.contains(id: credentialSource.id, kind: forwarding.authentication)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.tint)
                Text(credentialSource != nil ? "Duplicate Forwarding" : (isNew ? "Add Forwarding" : "Edit Forwarding"))
                    .font(.title2.weight(.semibold))
                Spacer()
            }.padding(22)
            Divider()
            Form {
                Section {
                    TextField("Label", text: $forwarding.label, prompt: Text("Development database"))
                    Picker("Group", selection: $forwarding.groupID) {
                        Text("Ungrouped").tag(nil as UUID?)
                        ForEach(store.groups) { group in
                            Text(group.name).tag(Optional(group.id))
                        }
                    }
                    Toggle("Keep this forwarding enabled", isOn: $forwarding.isEnabled)
                }
                Section {
                    TextField("Bind address", text: $forwarding.localBindAddress, prompt: Text("127.0.0.1"))
                    TextField("Local port", text: $localPort, prompt: Text("8080"))
                    Text("127.0.0.1 accepts connections from this Mac. Use 0.0.0.0 or :: to listen on other interfaces.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Local listener") }
                Section {
                    TextField("Host", text: $forwarding.sshHost, prompt: Text("bastion.example.com"))
                    TextField("SSH port", text: $sshPort, prompt: Text("22"))
                    TextField("Username", text: $forwarding.sshUsername, prompt: Text("deploy"))
                    Picker("Authentication", selection: $forwarding.authentication) {
                        ForEach(Authentication.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    if forwarding.authentication == .privateKey {
                        HStack {
                            TextField("Private key", text: $forwarding.privateKeyPath, prompt: Text("~/.ssh/id_ed25519"))
                            Button("Choose…", action: chooseKey)
                        }
                        SecureField("Key passphrase", text: $secret,
                                    prompt: Text(hasSavedSecret ? "Leave blank to keep saved passphrase" : "Optional for encrypted keys"))
                            .disabled(removePassphrase)
                        if hasSavedSecret {
                            Toggle("Remove saved passphrase", isOn: $removePassphrase)
                        }
                    } else if forwarding.authentication == .password {
                        SecureField("Password", text: $secret,
                                    prompt: Text(hasSavedSecret ? "Leave blank to keep saved password" : "SSH password"))
                    }
                    Text(forwarding.authentication == .agent
                         ? "Uses your SSH agent and standard key files. Load encrypted keys into the agent before connecting."
                         : "Passwords and key passphrases are stored in your macOS login Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("SSH connection") }
                Section {
                    TextField("Address", text: $forwarding.destinationHost, prompt: Text("localhost"))
                    TextField("Port", text: $destinationPort, prompt: Text("80"))
                    Text("The destination is resolved and reached from the SSH host. localhost means the remote host itself.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Destination") }
                Section {
                    Picker("Host key policy", selection: $forwarding.hostKeyPolicy) {
                        ForEach(HostKeyPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text(forwarding.hostKeyPolicy == .strict
                         ? "The host must already be in ~/.ssh/known_hosts. To verify a new host, copy the command below and run it in Terminal."
                         : "The first host key is saved automatically. Connections are refused if a known host key changes.")
                        .font(.caption).foregroundStyle(.secondary)
                    if forwarding.hostKeyPolicy == .strict {
                        Button(copied ? "Command Copied" : "Copy Host Verification Command", action: copyVerificationCommand)
                            .disabled(forwarding.sshHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: { Text("Host verification") }
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if let errorMessage {
                    Text(errorMessage).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text("Enabled connections reconnect automatically.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(isNew ? "Add Forwarding" : "Save", action: save)
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }.padding(18)
        }
        .frame(width: 640, height: 720)
        .onChange(of: forwarding.authentication) { _ in
            secret = ""
            removePassphrase = false
        }
    }

    private func save() {
        guard let local = Int(localPort), let ssh = Int(sshPort), let destination = Int(destinationPort) else {
            errorMessage = "Local, SSH, and destination ports must be whole numbers between 1 and 65535."
            return
        }
        var value = forwarding
        value.localPort = local
        value.sshPort = ssh
        value.destinationPort = destination
        let credential: String? = removePassphrase ? "" : (secret.isEmpty ? nil : secret)
        do {
            try store.save(value, secret: credential, copyingCredentialsFrom: credentialSource?.id)
            secret = ""
            onSave(value.id)
        } catch { errorMessage = error.localizedDescription }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.title = "Choose SSH Private Key"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url { forwarding.privateKeyPath = url.path }
    }

    private func copyVerificationCommand() {
        var value = forwarding.normalized()
        value.sshPort = Int(sshPort) ?? 22
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SSHCommand.verificationCommand(for: value), forType: .string)
        copied = true
    }
}
