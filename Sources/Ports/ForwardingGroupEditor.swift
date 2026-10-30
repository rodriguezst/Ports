import SwiftUI
import PortsCore

@MainActor struct ForwardingGroupEditor: View {
    @ObservedObject var store: AppStore
    let isNew: Bool
    let onSave: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var group: ForwardingGroup
    @State private var errorMessage: String?

    init(store: AppStore, group: ForwardingGroup, isNew: Bool, onSave: @escaping (UUID) -> Void) {
        self.store = store
        self.isNew = isNew
        self.onSave = onSave
        _group = State(initialValue: group)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(isNew ? "New Group" : "Rename Group", systemImage: "folder")
                .font(.title2.weight(.semibold))
            TextField("Group name", text: $group.name, prompt: Text("Development"))
                .textFieldStyle(.roundedBorder)
            Text("Add multiple forwardings to a group, then enable or disable them together in Settings or the menu bar. Change a forwarding’s group in its editor.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Create Group" : "Save") {
                    do {
                        try store.saveGroup(group)
                        onSave(group.id)
                    } catch { errorMessage = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 440)
    }
}
