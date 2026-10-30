import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PortsCore

private struct TunnelTransferRequest: Identifiable {
    let id = UUID()
    let configuration: Configuration
}

@MainActor struct TunnelTransferControls: View {
    @ObservedObject var store: AppStore
    let onImport: (UUID) -> Void
    @State private var exportRequest: TunnelTransferRequest?
    @State private var importRequest: TunnelTransferRequest?

    var body: some View {
        HStack {
            Button(action: chooseImport) { Label("Import…", systemImage: "square.and.arrow.down") }
                .help("Import selected tunnels from a Ports configuration file")
                .disabled(store.configurationUnavailable)
            Button {
                exportRequest = TunnelTransferRequest(configuration: store.configuration)
            } label: { Label("Export…", systemImage: "square.and.arrow.up") }
            .help("Choose one or more tunnels to export")
            .disabled(store.configurationUnavailable || store.forwardings.isEmpty)
            .popover(item: $exportRequest, arrowEdge: .bottom) { request in
                TunnelSelectionView(configuration: request.configuration, title: "Export Tunnels",
                                    actionTitle: "Export…",
                                    explanation: "Choose the tunnels to include in the exported file.",
                                    footer: "Group information is included. Passwords, passphrases, and private key files are not exported.",
                                    cancel: { exportRequest = nil }) { identifiers in
                    exportRequest = nil
                    export(request.configuration, selecting: identifiers)
                }
            }
        }
        .controlSize(.small)
        .sheet(item: $importRequest) { request in
            TunnelSelectionView(configuration: request.configuration, title: "Import Tunnels",
                                actionTitle: "Import Selected",
                                explanation: "Choose the tunnels to add. All tunnels are selected by default.",
                                footer: "Existing tunnels are kept. Imported tunnels start disabled. Add any required passwords or key passphrases in their editors before enabling them.",
                                cancel: { importRequest = nil }) { identifiers in
                let importedIDs = try store.importForwardings(from: request.configuration, selecting: identifiers)
                if let first = importedIDs.first { onImport(first) }
                importRequest = nil
            }
        }
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.title = "Import Tunnels"
        panel.message = "Choose a Ports configuration file. You can select which tunnels to import next."
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let configuration = try ConfigurationStore(url: url).load()
            guard !configuration.forwardings.isEmpty else {
                throw ConfigurationError("This file does not contain any tunnels to import.")
            }
            importRequest = TunnelTransferRequest(configuration: configuration)
        } catch { store.errorMessage = "Could not import tunnels.\n\n\(error.localizedDescription)" }
    }

    private func export(_ configuration: Configuration, selecting identifiers: Set<UUID>) {
        do {
            let selected = try configuration.selectingForwardings(identifiers)
            let panel = NSSavePanel()
            panel.title = "Export Tunnels"
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "Ports-tunnels.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            guard url.standardizedFileURL.resolvingSymlinksInPath() != store.configurationURL.standardizedFileURL.resolvingSymlinksInPath() else {
                throw ConfigurationError("Choose a different export file. This file stores Ports’ active configuration.")
            }
            try ConfigurationStore(url: url).save(selected)
        } catch { store.errorMessage = "Could not export tunnels.\n\n\(error.localizedDescription)" }
    }
}

@MainActor private struct TunnelSelectionView: View {
    let configuration: Configuration
    let title: String
    let actionTitle: String
    let explanation: String
    let footer: String
    let cancel: () -> Void
    let confirm: (Set<UUID>) throws -> Void
    @State private var selectedIDs: Set<UUID>
    @State private var errorMessage: String?

    init(configuration: Configuration, title: String, actionTitle: String, explanation: String,
         footer: String, cancel: @escaping () -> Void, confirm: @escaping (Set<UUID>) throws -> Void) {
        self.configuration = configuration
        self.title = title
        self.actionTitle = actionTitle
        self.explanation = explanation
        self.footer = footer
        self.cancel = cancel
        self.confirm = confirm
        _selectedIDs = State(initialValue: Set(configuration.forwardings.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.weight(.semibold))
            Text(explanation).foregroundStyle(.secondary)
            HStack {
                Button("Select All") { selectedIDs = Set(configuration.forwardings.map(\.id)) }
                Button("Deselect All") { selectedIDs.removeAll() }
                Spacer()
                Text("\(selectedIDs.count) of \(configuration.forwardings.count) selected")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(configuration.groups) { group in
                        let members = configuration.members(of: group.id)
                        if !members.isEmpty {
                            Label(group.name, systemImage: "folder").font(.headline)
                            ForEach(members) { forwarding in tunnelRow(forwarding) }
                        }
                    }
                    if !configuration.groups.isEmpty && !configuration.members(of: nil).isEmpty {
                        Text("Ungrouped").font(.headline)
                    }
                    ForEach(configuration.members(of: nil)) { forwarding in tunnelRow(forwarding) }
                }
                .padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 280)
            Divider()
            Text(footer).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button(actionTitle) {
                    do { try confirm(selectedIDs) }
                    catch { errorMessage = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(selectedIDs.isEmpty)
            }
        }
        .padding(24).frame(width: 540)
    }

    private func tunnelRow(_ forwarding: Forwarding) -> some View {
        Toggle(isOn: Binding(
            get: { selectedIDs.contains(forwarding.id) },
            set: { included in
                if included { selectedIDs.insert(forwarding.id) }
                else { selectedIDs.remove(forwarding.id) }
            }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                Text(forwarding.label).fontWeight(.medium)
                Text("\(forwarding.localEndpoint) → \(forwarding.destinationEndpoint)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                Text("via \(forwarding.sshEndpoint)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
    }
}
