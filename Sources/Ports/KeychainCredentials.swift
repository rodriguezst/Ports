import Foundation
import Security
import PortsCore

enum KeychainCredentials {
    private static let service = "app.ports.credentials"

    private static func query(id: UUID, kind: Authentication) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "\(id.uuidString).\(kind.rawValue)"]
    }

    static func read(id: UUID, kind: Authentication) throws -> String? {
        var query = query(id: id, kind: kind)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw KeychainError(status: status) }
        return value
    }

    static func contains(id: UUID, kind: Authentication) -> Bool {
        var query = query(id: id, kind: kind)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var attributes: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &attributes) == errSecSuccess
    }

    static func write(_ secret: String, id: UUID, kind: Authentication) throws {
        let query = query(id: id, kind: kind)
        if secret.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let data = Data(secret.utf8)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Ports SSH \(kind == .password ? "password" : "key passphrase")"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func delete(id: UUID) throws {
        for kind in [Authentication.password, .privateKey] { try write("", id: id, kind: kind) }
    }
}

private struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        "Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)")"
    }
}

/// OpenSSH invokes the same signed executable in helper mode. Only a connection
/// identifier travels in the environment; the credential is read from Keychain
/// and returned over the helper's stdout pipe, never a file or a shell command.
enum Askpass {
    static func run(environment: [String: String], arguments: [String]) -> Int32 {
        guard let rawID = environment["PORTS_ASKPASS_ID"], let id = UUID(uuidString: rawID),
              let rawKind = environment["PORTS_ASKPASS_KIND"], let kind = Authentication(rawValue: rawKind),
              arguments.count == 2 else { return 1 }
        let prompt = arguments[1].lowercased()
        switch kind {
        case .password: guard prompt.contains("password:") else { return 1 }
        case .privateKey: guard prompt.contains("passphrase for key") else { return 1 }
        case .agent: return 1
        }
        do {
            guard let secret = try KeychainCredentials.read(id: id, kind: kind) else { return 1 }
            FileHandle.standardOutput.write(Data((secret + "\n").utf8))
            return 0
        } catch { return 1 }
    }
}
