import AppKit
import SwiftUI
import PortsCore

private struct EditorRequest: Identifiable {
    let forwarding: Forwarding
    let isNew: Bool
    var id: UUID { forwarding.id }
}

@MainActor struct SettingsView: View {
    @ObservedObject var store: AppStore
    @State private var selection: UUID?
    @State private var editor: EditorRequest?
    @State private var confirmingDeletion = false

    private var selected: Forwarding? { store.forwardings.first { $0.id == selection } }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Forwardings").font(.headline)
                    Spacer()
                    Button(action: add) { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("Add a port forwarding")
                        .disabled(store.configurationUnavailable)
                }
                .padding(16)
                List(selection: $selection) {
                    ForEach(store.forwardings) { forwarding in
                        HStack(spacing: 10) {
                            StateIndicator(state: store.states[forwarding.id] ?? .disabled, compact: true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(forwarding.label).fontWeight(.medium).lineLimit(1)
                                Text(forwarding.localEndpoint)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if forwarding.isEnabled {
                                Image(systemName: "checkmark").font(.caption.weight(.semibold))
                                    .accessibilityLabel("Enabled")
                            }
                        }
                        .padding(.vertical, 5)
                        .tag(forwarding.id)
                    }
                }
                .listStyle(.sidebar)
                Divider()
                HStack {
                    Text("\(store.forwardings.filter(\.isEnabled).count) enabled")
                    Spacer()
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .help("Enabled forwardings reconnect automatically")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(14)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            if store.configurationUnavailable {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 40)).foregroundStyle(.orange)
                    Text("Configuration could not be loaded").font(.title2.weight(.semibold))
                    Text("Your saved file has been preserved. Fix or move it, then reload to continue.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Text(store.configurationURL.path).font(.caption.monospaced()).textSelection(.enabled)
                    Button("Reload Configuration") { store.loadConfiguration() }
                        .buttonStyle(.borderedProminent)
                }.padding(36)
            } else if let selected {
                ForwardingDetail(
                    forwarding: selected,
                    state: store.states[selected.id] ?? .disabled,
                    setEnabled: { store.setEnabled($0, id: selected.id) },
                    edit: { editor = EditorRequest(forwarding: selected, isNew: false) },
                    reconnect: { store.reconnect(selected.id) },
                    delete: { confirmingDeletion = true }
                )
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 46, weight: .light)).foregroundStyle(.tint)
                    Text(store.forwardings.isEmpty ? "Your connections, one click away" : "Select a forwarding")
                        .font(.title2.weight(.semibold))
                    Text("Forward a local port through SSH. Ports keeps enabled connections running, even after network interruptions.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                    Button(action: add) { Label("Add Forwarding", systemImage: "plus") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }.padding(36)
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        .sheet(item: $editor) { request in
            ForwardingEditor(store: store, forwarding: request.forwarding, isNew: request.isNew) { savedID in
                selection = savedID
                editor = nil
            }
        }
        .alert("Ports", isPresented: Binding(
            get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .alert("Delete “\(selected?.label ?? "forwarding")”?", isPresented: $confirmingDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let selection { store.delete(selection) }
                selection = store.forwardings.first?.id
            }
        } message: { Text("This stops the forwarding and removes its saved credentials from Keychain.") }
        .onAppear { if selection == nil { selection = store.forwardings.first?.id } }
    }

    private func add() {
        editor = EditorRequest(forwarding: Forwarding(sshUsername: NSUserName()), isNew: true)
    }
}

private struct ForwardingDetail: View {
    let forwarding: Forwarding
    let state: TunnelState
    let setEnabled: (Bool) -> Void
    let edit: () -> Void
    let reconnect: () -> Void
    let delete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(forwarding.label).font(.largeTitle.weight(.semibold)).textSelection(.enabled)
                        StateIndicator(state: state)
                    }
                    Spacer()
                    Toggle("Enabled", isOn: Binding(get: { forwarding.isEnabled }, set: setEnabled))
                        .toggleStyle(.switch).fixedSize()
                }
                Text(state.detail).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        endpoint("Local listener", icon: "laptopcomputer", address: forwarding.localEndpoint)
                        HStack {
                            Image(systemName: "arrow.down").foregroundStyle(.tertiary).frame(width: 24)
                            Text("Encrypted SSH tunnel").font(.caption).foregroundStyle(.secondary)
                        }
                        endpoint("SSH host", icon: "lock.shield", address: forwarding.sshEndpoint)
                        HStack {
                            Image(systemName: "arrow.down").foregroundStyle(.tertiary).frame(width: 24)
                            Text("Destination reached from the SSH host").font(.caption).foregroundStyle(.secondary)
                        }
                        endpoint("Destination", icon: "server.rack", address: forwarding.destinationEndpoint)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }

                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                    GridRow {
                        Text("Authentication").foregroundStyle(.secondary)
                        Text(forwarding.authentication.title)
                    }
                    if forwarding.authentication == .privateKey {
                        GridRow {
                            Text("Private key").foregroundStyle(.secondary)
                            Text(forwarding.privateKeyPath).font(.callout.monospaced()).textSelection(.enabled)
                        }
                    }
                    GridRow {
                        Text("Host verification").foregroundStyle(.secondary)
                        Text(forwarding.hostKeyPolicy.title)
                    }
                }.font(.callout)

                HStack {
                    Button("Edit…", action: edit)
                    Button("Reconnect Now", action: reconnect).disabled(!forwarding.isEnabled)
                    Spacer()
                    Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                        .help("Delete forwarding")
                }
                Divider()
                Label("A tick in the menu means enabled. Ports reconnects automatically after network cuts and sleep, and restores enabled connections when it opens.",
                      systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }
    }

    private func endpoint(_ title: String, icon: String, address: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(.tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(address).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }
        }
    }
}

private struct StateIndicator: View {
    let state: TunnelState
    var compact = false

    private var color: Color {
        switch state {
        case .connected: return .green
        case .disabled: return .secondary
        case .connecting, .retrying: return .orange
        case .waitingForNetwork, .sleeping: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            if !compact { Text(state.title).font(.callout).foregroundStyle(color) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.title)
    }
}
