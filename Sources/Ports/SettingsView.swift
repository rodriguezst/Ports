import AppKit
import SwiftUI
import PortsCore

private struct EditorRequest: Identifiable {
    let forwarding: Forwarding
    let isNew: Bool
    var credentialSource: Forwarding? = nil
    var id: UUID { forwarding.id }
}

private struct GroupEditorRequest: Identifiable {
    let group: ForwardingGroup
    let isNew: Bool
    var id: UUID { group.id }
}

private enum SettingsSelection: Hashable {
    case forwarding(UUID)
    case group(UUID)
}

@MainActor struct SettingsView: View {
    @ObservedObject var store: AppStore
    @State private var selection: SettingsSelection?
    @State private var editor: EditorRequest?
    @State private var confirmingDeletion = false
    @State private var groupEditor: GroupEditorRequest?
    @State private var confirmingGroupDeletion = false

    private var selected: Forwarding? {
        guard case .forwarding(let id) = selection else { return nil }
        return store.forwardings.first { $0.id == id }
    }

    private var selectedGroup: ForwardingGroup? {
        guard case .group(let id) = selection else { return nil }
        return store.groups.first { $0.id == id }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Forwardings").font(.headline)
                    Spacer()
                    Menu {
                        Button("Add Forwarding…", action: add)
                        Button("New Group…", action: addGroup)
                    } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Add a forwarding or group")
                    .disabled(store.configurationUnavailable)
                }
                .padding(16)
                List(selection: $selection) {
                    ForEach(store.groups) { group in
                        groupRow(group)
                        ForEach(store.configuration.members(of: group.id)) { forwarding in
                            forwardingRow(forwarding).padding(.leading, 12)
                        }
                    }
                    if !store.groups.isEmpty && !store.configuration.members(of: nil).isEmpty {
                        Section("Ungrouped") {
                            ForEach(store.configuration.members(of: nil)) { forwarding in
                                forwardingRow(forwarding)
                            }
                        }
                    } else {
                        ForEach(store.configuration.members(of: nil)) { forwarding in
                            forwardingRow(forwarding)
                        }
                    }
                }
                .listStyle(.sidebar)
                Divider()
                TunnelTransferControls(store: store) { selection = .forwarding($0) }
                    .padding(.horizontal, 14).padding(.vertical, 10)
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
            } else if let selectedGroup {
                ForwardingGroupDetail(store: store, group: selectedGroup,
                                      add: { addForwarding(to: selectedGroup.id) },
                                      edit: { groupEditor = GroupEditorRequest(group: selectedGroup, isNew: false) },
                                      delete: { confirmingGroupDeletion = true },
                                      select: { selection = .forwarding($0) })
            } else if let selected {
                ForwardingDetail(
                    forwarding: selected,
                    groupName: store.groups.first { $0.id == selected.groupID }?.name,
                    state: store.states[selected.id] ?? .disabled,
                    setEnabled: { store.setEnabled($0, id: selected.id) },
                    edit: { editor = EditorRequest(forwarding: selected, isNew: false) },
                    duplicate: { duplicate(selected) },
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
                    Button("New Group…", action: addGroup)
                }.padding(36)
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        .sheet(item: $editor) { request in
            ForwardingEditor(store: store, forwarding: request.forwarding, isNew: request.isNew,
                             credentialSource: request.credentialSource) { savedID in
                selection = .forwarding(savedID)
                editor = nil
            }
        }
        .sheet(item: $groupEditor) { request in
            ForwardingGroupEditor(store: store, group: request.group, isNew: request.isNew) { savedID in
                selection = .group(savedID)
                groupEditor = nil
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
                if let selected { store.delete(selected.id) }
                selection = store.forwardings.first.map { .forwarding($0.id) }
            }
        } message: { Text("This stops the forwarding and removes its saved credentials from Keychain.") }
        .alert("Delete “\(selectedGroup?.name ?? "group")”?", isPresented: $confirmingGroupDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Group", role: .destructive) {
                if let selectedGroup { store.deleteGroup(selectedGroup.id) }
                selection = nil
            }
        } message: { Text("Its forwardings will become ungrouped and keep their enabled settings.") }
        .onAppear {
            if selection == nil { selection = store.forwardings.first.map { .forwarding($0.id) } }
        }
    }

    private func add() {
        addForwarding(to: selectedGroup?.id ?? selected?.groupID)
    }

    private func addForwarding(to groupID: UUID?) {
        editor = EditorRequest(forwarding: Forwarding(sshUsername: NSUserName(), groupID: groupID), isNew: true)
    }

    private func addGroup() {
        groupEditor = GroupEditorRequest(group: ForwardingGroup(), isNew: true)
    }

    private func forwardingRow(_ forwarding: Forwarding) -> some View {
        HStack(spacing: 10) {
            StateIndicator(state: store.states[forwarding.id] ?? .disabled, compact: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(forwarding.label).fontWeight(.medium).lineLimit(1)
                Text(forwarding.localEndpoint)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if forwarding.isEnabled {
                Image(systemName: "checkmark").font(.caption.weight(.semibold))
                    .accessibilityLabel("Enabled")
            }
        }
        .padding(.vertical, 5)
        .tag(SettingsSelection.forwarding(forwarding.id))
        .contextMenu {
            Button("Duplicate…") { duplicate(forwarding) }
                .disabled(store.configurationUnavailable)
        }
    }

    private func groupRow(_ group: ForwardingGroup) -> some View {
        let members = store.configuration.members(of: group.id)
        let state = store.configuration.enabledState(of: group.id)
        return HStack(spacing: 10) {
            Image(systemName: "folder").foregroundStyle(.tint)
            Text(group.name).fontWeight(.semibold).lineLimit(1)
            Spacer(minLength: 0)
            Text("\(members.count)").font(.caption).foregroundStyle(.secondary)
            if state != .disabled {
                Image(systemName: state == .enabled ? "checkmark" : "minus")
                    .font(.caption.weight(.semibold))
                    .accessibilityLabel(state == .enabled ? "All enabled" : "Some enabled")
            }
        }
        .padding(.vertical, 5)
        .tag(SettingsSelection.group(group.id))
        .contextMenu {
            Button("Add Forwarding…") { addForwarding(to: group.id) }
            Button(state == .enabled ? "Disable All" : "Enable All") {
                store.setGroupEnabled(state != .enabled, id: group.id)
            }.disabled(members.isEmpty)
            Button("Rename…") { groupEditor = GroupEditorRequest(group: group, isNew: false) }
        }
    }

    private func duplicate(_ forwarding: Forwarding) {
        let copy = forwarding.duplicated(existingLabels: Set(store.forwardings.map(\.label)))
        editor = EditorRequest(forwarding: copy, isNew: true, credentialSource: forwarding)
    }
}

@MainActor private struct ForwardingGroupDetail: View {
    @ObservedObject var store: AppStore
    let group: ForwardingGroup
    let add: () -> Void
    let edit: () -> Void
    let delete: () -> Void
    let select: (UUID) -> Void

    private var members: [Forwarding] { store.configuration.members(of: group.id) }
    private var enabledCount: Int { members.filter(\.isEnabled).count }
    private var connectedCount: Int { members.filter { store.states[$0.id] == .connected }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Label(group.name, systemImage: "folder").font(.largeTitle.weight(.semibold))
                    .textSelection(.enabled)
                Text("\(enabledCount) of \(members.count) enabled · \(connectedCount) connected")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Enable All") { store.setGroupEnabled(true, id: group.id) }
                        .disabled(members.isEmpty || enabledCount == members.count)
                    Button("Disable All") { store.setGroupEnabled(false, id: group.id) }
                        .disabled(enabledCount == 0)
                }
                if members.isEmpty {
                    Text("Add port forwardings to this group, or choose this group when editing an existing forwarding.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(members) { forwarding in
                        GroupBox {
                            HStack {
                                VStack(alignment: .leading, spacing: 6) {
                                    Button(forwarding.label) { select(forwarding.id) }
                                        .buttonStyle(.link).font(.headline)
                                    Text("\(forwarding.localEndpoint) → \(forwarding.destinationEndpoint)")
                                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                                    StateIndicator(state: store.states[forwarding.id] ?? .disabled)
                                }
                                Spacer()
                                Toggle("Enabled", isOn: Binding(
                                    get: { forwarding.isEnabled },
                                    set: { store.setEnabled($0, id: forwarding.id) }
                                )).toggleStyle(.switch).fixedSize()
                            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                HStack {
                    Button(action: add) { Label("Add Forwarding…", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                    Button("Rename…", action: edit)
                    Spacer()
                    Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                        .help("Delete group")
                }
                Divider()
                Text("Group controls change every forwarding’s enabled choice. Each port keeps its own connection status and reconnects independently.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }
    }
}

private struct ForwardingDetail: View {
    let forwarding: Forwarding
    let groupName: String?
    let state: TunnelState
    let setEnabled: (Bool) -> Void
    let edit: () -> Void
    let duplicate: () -> Void
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
                        Text("Group").foregroundStyle(.secondary)
                        Text(groupName ?? "Ungrouped")
                    }
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
                    Button("Duplicate…", action: duplicate)
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
