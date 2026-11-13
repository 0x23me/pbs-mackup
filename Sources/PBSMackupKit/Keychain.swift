import Foundation
import Security

/// The API token secret and the encryption key live in the login Keychain and nowhere else.
///
/// The Keychain hands an item to the program that stored it, which it knows by its signing
/// identifier and its developer, not by its version. So every released run tool that signs as
/// `Identity.toolIdentifier` can read these items for good, and none of them may ever hand a
/// secret to a caller it has not checked. The run tools before 0.2 did; they signed under
/// another identifier and kept their items under another service (`legacyService`), so they
/// cannot read these.
public enum Keychain {
    public enum Item: String, CaseIterable {
        case token
        case encryptionKey = "encryption-key"
    }
    public static var service: String { Identity.toolIdentifier }
    /// Where the versions before 0.2 kept the items; see `migrate`.
    static var legacyService: String { Identity.bundleID }

    public struct Failure: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }

    private static func query(_ item: Item, service: String = Keychain.service) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: item.rawValue]
    }

    /// With `PBS_MACKUP_HOME` set, which only the tests do and only a development build looks at,
    /// secrets are files under that folder, so a test never reads or writes the login Keychain.
    private static func testFile(_ item: Item) -> URL? {
        Paths.override?.appendingPathComponent("secrets/\(item.rawValue)")
    }

    /// Stores the item. A key is also noted in the seal: the key to go by from now on.
    public static func set(_ item: Item, _ value: Data) throws {
        if let file = testFile(item) {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try value.write(to: file)
        } else {
            let status = SecItemUpdate(query(item) as CFDictionary, [kSecValueData as String: value] as CFDictionary)
            if status == errSecItemNotFound {
                var add = query(item)
                add[kSecValueData as String] = value
                let added = SecItemAdd(add as CFDictionary, nil)
                guard added == errSecSuccess else { throw Failure(status: added) }
            } else if status != errSecSuccess {
                throw Failure(status: status)
            }
        }
        if item == .encryptionKey { try Seal.set(key: value) }
    }

    /// Nil when the item does not exist.
    public static func get(_ item: Item) throws -> Data? {
        if let file = testFile(item) { return try? Data(contentsOf: file) }
        return try read(query(item))
    }

    private static func read(_ query: [String: Any]) throws -> Data? {
        var find = query
        find[kSecReturnData as String] = true
        find[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(find as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        return result as? Data
    }

    /// Whether a version before 0.2 left this item where it kept it. Looking for an item
    /// without asking for its secret needs nobody's permission.
    static func hasLegacy(_ item: Item) -> Bool {
        guard Paths.override == nil else { return false }
        var probe = query(item, service: legacyService), found: CFTypeRef?
        probe[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(probe as CFDictionary, &found) == errSecSuccess
    }

    /// Takes over the items a version before 0.2 stored, and removes them where that version
    /// kept them, so that its run tool, which hands the key to whoever asks, finds nothing any
    /// more. This tool is a stranger to those items: macOS asks the owner for the login
    /// password before it hands each one over. Returns the items that were moved. What the
    /// earlier version used is what counts: it takes the place of an item that is already here.
    @discardableResult
    public static func migrate() throws -> [Item] {
        var moved: [Item] = []
        for item in Item.allCases where hasLegacy(item) {
            let old = query(item, service: legacyService)
            guard let value = try read(old) else { continue }
            if try get(item) != value { try set(item, value) }
            guard try get(item) == value else { continue }      // the old one stays until the new one reads back
            SecItemDelete(old as CFDictionary)
            moved.append(item)
        }
        return moved
    }
}
