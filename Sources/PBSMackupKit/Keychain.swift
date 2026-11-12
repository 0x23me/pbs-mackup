import Foundation
import Security

/// The API token secret and the encryption key live in the login Keychain and nowhere else.
public enum Keychain {
    public enum Item: String {
        case token
        case encryptionKey = "encryption-key"
    }
    public static var service: String { Identity.bundleID }

    public struct Failure: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }

    private static func query(_ item: Item) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: item.rawValue]
    }

    /// With `PBS_MACKUP_HOME` set, which only the tests do, secrets are files under that folder, so
    /// a test never reads or writes the login Keychain.
    private static func testFile(_ item: Item) -> URL? {
        Paths.override?.appendingPathComponent("secrets/\(item.rawValue)")
    }

    public static func set(_ item: Item, _ value: Data) throws {
        if let file = testFile(item) {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try value.write(to: file)
            return
        }
        let status = SecItemUpdate(query(item) as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw Failure(status: status) }
        var add = query(item)
        add[kSecValueData as String] = value
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure(status: added) }
    }

    /// Nil when the item does not exist.
    public static func get(_ item: Item) throws -> Data? {
        if let file = testFile(item) { return try? Data(contentsOf: file) }
        var find = query(item)
        find[kSecReturnData as String] = true
        find[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(find as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        return result as? Data
    }
}
