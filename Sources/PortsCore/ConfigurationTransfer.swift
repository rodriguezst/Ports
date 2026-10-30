import Foundation

extension Configuration {
    /// Export only the chosen tunnels and the groups needed to describe them.
    public func selectingForwardings(_ identifiers: Set<UUID>) throws -> Configuration {
        try validate()
        guard !identifiers.isEmpty else {
            throw ConfigurationError("Select at least one tunnel.")
        }
        guard identifiers.isSubset(of: Set(forwardings.map(\.id))) else {
            throw ConfigurationError("A selected tunnel no longer exists. Open the selection again.")
        }
        let selected = forwardings.filter { identifiers.contains($0.id) }
        let groupIDs = Set(selected.compactMap(\.groupID))
        return Configuration(forwardings: selected, groups: groups.filter { groupIDs.contains($0.id) })
    }

    /// Imports append new, disabled tunnels without sharing existing credential IDs.
    public func importingForwardings(from source: Configuration, selecting identifiers: Set<UUID>) throws -> Configuration {
        try validate()
        let selected = try source.selectingForwardings(identifiers)
        var next = self
        var groupIDs: [UUID: UUID] = [:]
        var groupNames = Set(groups.map(\.name))
        for group in selected.groups {
            if let existing = groups.first(where: { $0.id == group.id && $0.name == group.name }) {
                groupIDs[group.id] = existing.id
                continue
            }
            var imported = group
            if next.groups.contains(where: { $0.id == imported.id }) { imported.id = UUID() }
            imported.name = Self.importedName(group.name, existing: groupNames)
            groupIDs[group.id] = imported.id
            groupNames.insert(imported.name)
            next.groups.append(imported)
        }
        var labels = Set(forwardings.map(\.label))
        for forwarding in selected.forwardings {
            var imported = forwarding
            imported.id = UUID()
            imported.isEnabled = false
            imported.groupID = forwarding.groupID.flatMap { groupIDs[$0] }
            imported.label = Self.importedName(forwarding.label, existing: labels)
            labels.insert(imported.label)
            next.forwardings.append(imported)
        }
        try next.validate()
        return next
    }

    private static func importedName(_ name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        var number = 1
        while true {
            let suffix = number == 1 ? " (Imported)" : " (Imported \(number))"
            let candidate = String(name.prefix(120 - suffix.count)) + suffix
            if !existing.contains(candidate) { return candidate }
            number += 1
        }
    }
}
