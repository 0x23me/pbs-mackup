import Foundation
import Security

/// The API token secret and the encryption key live in the Keychain and nowhere else.
///
/// A run tool that was built with a provisioning profile (see `Scripts/bundle.sh`) keeps them
/// in the data protection keychain, in an access group that begins with the developer's Team
/// ID. macOS lets only a program in that group read, make, replace or delete such an item, and
/// a program is in the group only when its developer's profile says so: no program of another
/// developer is, and of this developer's only the run tool, not the app and not the client.
///
/// Any other build keeps them in the login keychain, as the releases 0.2 to 0.5 did. That
/// keychain hands an item to the program that stored it, which it knows by its signing
/// identifier and its developer, not by its version, and it lets any program delete an item
/// and put one of its own in its place. The first run tool with a profile takes the items out
/// of there (`get`), so the run tools of those releases, which know no other place, find
/// nothing. The run tools before 0.2 kept their items under another service, the bundle
/// identifier itself; nothing is taken over from that service.
public enum Keychain {
    public enum Item: String, CaseIterable {
        case token
        case encryptionKey = "encryption-key"
    }
    public static var service: String { Identity.toolIdentifier }

    public struct Failure: Error, CustomStringConvertible {
        public let status: OSStatus
        /// The item that was to be stored, when what lies in its place could not be removed.
        var held: Item? = nil
        public var description: String {
            let said = (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
            guard let held else { return said }
            return "Another program holds a Keychain item named \(Keychain.service) (account \(held.rawValue)) and could read "
                + "what is stored in it, so nothing was stored (\(said)). Delete that item in Keychain Access, then try again."
        }
    }

    /// Where the items are.
    enum Place: Equatable {
        /// The login keychain.
        case login
        /// The data protection keychain, in this access group.
        case guarded(group: String)
    }

    /// The data protection keychain for a program that is in the access group made of the
    /// developer's Team ID and the bundle identifier, the login keychain for any other.
    /// `groups` is what macOS says the running program's `keychain-access-groups` are: it is
    /// macOS that lets a program into a group or not, by its signature and its profile, so
    /// that is asked and nothing is concluded from where the program lies.
    static func place(groups: [String]?, team: String?, bundleID: String) -> Place {
        guard let team, let groups, groups.contains("\(team).\(bundleID)") else { return .login }
        return .guarded(group: "\(team).\(bundleID)")
    }

    static let place: Place = {
        let groups = SecTaskCreateFromSelf(nil).flatMap {
            SecTaskCopyValueForEntitlement($0, "keychain-access-groups" as CFString, nil) as? [String]
        }
        return place(groups: groups, team: Identity.team, bundleID: Identity.bundleID)
    }()

    private static func query(_ item: Item, in place: Place) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: item.rawValue]
        switch place {
        case .login:
            // Said, not left out: for a program in an access group a query that does not say
            // looks in both keychains, and would find, or remove, the item in the other one.
            query[kSecUseDataProtectionKeychain as String] = false
        case .guarded(let group):
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrAccessGroup as String] = group
        }
        return query
    }

    /// The item in `place`. Made there, it is for this Mac alone and can be read while the Mac
    /// is locked, since a backup also runs then; the login keychain has no such choice.
    private static func store(_ item: Item, in place: Place) -> Store {
        Store(
            delete: { place == .login ? removeFromLogin(item) : SecItemDelete(query(item, in: place) as CFDictionary) },
            add: { value in
                var add = query(item, in: place)
                add[kSecValueData as String] = value
                if place != .login { add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }
                return SecItemAdd(add as CFDictionary, nil)
            },
            read: { try read(query(item, in: place)) })
    }

    /// The item an earlier version left in the login keychain, for a run tool that keeps its
    /// items elsewhere. macOS never asks the owner about it: this tool reads what a run tool
    /// stored without a question, and an item that another program put there, which macOS
    /// would ask about, counts as not there.
    private static func left(_ item: Item) -> Store {
        let login = store(item, in: .login)
        return Store(
            delete: { Legacy.unasked.withoutQuestions { login.delete() } },
            add: login.add,
            read: { try Legacy.unasked.withoutQuestions { try login.read() } })
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
        } else if place == .login {
            try replace(item, with: value, in: store(item, in: .login))
        } else {
            // No other developer's program can hold an item here, so a failure is said as
            // the Keychain says it.
            do { try replace(item, with: value, in: store(item, in: place)) } catch let failure as Failure {
                throw Failure(status: failure.status)
            }
            // What an earlier version left behind is of no use from now on.
            _ = left(item).delete()
        }
        if item == .encryptionKey { try Seal.set(key: value) }
    }

    /// One item of the Keychain as `replace` and `get` work on it, so that a test can stand in
    /// for it.
    struct Store {
        let delete: () -> OSStatus
        let add: (Data) -> OSStatus
        /// Nil when the item does not exist.
        var read: () throws -> Data? = { nil }
    }

    /// Puts `value` in the item's place: what lies there is removed and the item made anew. An
    /// item is never changed where it lies. The Keychain lets the program that made an item go
    /// on reading it, and lets any program write into it, so an item that another program put
    /// there under this name would take the secret and hand it to that program. Made anew, the
    /// item is this tool's alone. An item of another program that cannot be removed takes
    /// nothing, and the failure says what to do. What was there is not read first, which
    /// would have macOS ask the owner to let this tool into the other program's item.
    static func replace(_ item: Item, with value: Data, in store: Store) throws {
        let removed = store.delete()
        guard removed == errSecSuccess || removed == errSecItemNotFound else { throw Failure(status: removed, held: item) }
        let added = store.add(value)
        // An item that is there again right after it was removed is another program's as well.
        guard added == errSecSuccess else { throw Failure(status: added, held: added == errSecDuplicateItem ? item : nil) }
    }

    /// Nil when the item does not exist.
    public static func get(_ item: Item) throws -> Data? {
        if let file = testFile(item) { return try? Data(contentsOf: file) }
        guard place != .login else { return try store(item, in: .login).read() }
        return try get(item, in: store(item, in: place), before: left(item), holds: Seal.holds(key:))
    }

    /// The item for a run tool that keeps its items in `store` and whose earlier versions kept
    /// them in `before`, the login keychain. As long as `store` has no item, the one in
    /// `before` is taken over and removed there, so that an earlier run tool finds nothing.
    /// Once `store` has the item, what is in `before` is not read any more, only removed.
    ///
    /// Any program can put an item into the login keychain, so what lies there is not simply
    /// this app's. The encryption key is taken over only when the seal holds it (`holds`).
    /// Another key is handed on as it is and stays where it is: `Client` and `Setup` then say
    /// that it is not the key this app put there, and the owner imports the recovery copy,
    /// which `set` stores in the new place. The token has no seal and is taken over as it is.
    /// A token that another program put there only makes the server refuse the backups,
    /// which the owner is told; the server it is sent to is the one in the sealed settings.
    static func get(_ item: Item, in store: Store, before: Store, holds: (Data) -> Bool) throws -> Data? {
        if let value = try store.read() {
            // What an earlier run could not remove there is removed now.
            _ = before.delete()
            return value
        }
        // An item there that cannot be read is not this tool's.
        guard let left = try? before.read() else { return nil }
        guard item != .encryptionKey || holds(left) else { return left }
        // Removed there only once it is here. Where it cannot be stored it still serves, and
        // the next time is tried again.
        guard (try? replace(item, with: left, in: store)) != nil else { return left }
        _ = before.delete()
        return left
    }

    /// Removes the item from the login keychain. The item is looked up and removed as what
    /// was found: asked to remove what matches a description (`SecItemDelete`), the login
    /// keychain refuses an item that another build of this same tool made, with
    /// `errSecInvalidOwnerEdit`, and every update is another build.
    private static func removeFromLogin(_ item: Item) -> OSStatus {
        var find = query(item, in: .login)
        find[kSecReturnRef as String] = true
        find[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        let status = SecItemCopyMatching(find as CFDictionary, &found)
        guard status == errSecSuccess, let found else { return status == errSecSuccess ? errSecItemNotFound : status }
        return Legacy.unasked.remove(found)
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

    /// The login keychain without its questions to the owner. The functions for that are
    /// deprecated along with everything else that is only for the login keychain, and have no
    /// successor; they are reached through a protocol so that the build stays free of warnings.
    private protocol Unasked {
        func withoutQuestions<T>(_ work: () throws -> T) rethrows -> T
        func remove(_ found: CFTypeRef) -> OSStatus
    }

    private struct Legacy: Unasked {
        static let unasked: Unasked = Legacy()
        private static let lock = NSLock()

        /// Does `work` while the login keychain may not ask the owner anything: what it would
        /// ask about fails instead. The switch is the whole program's, so one at a time.
        @available(macOS, deprecated: 10.10)
        func withoutQuestions<T>(_ work: () throws -> T) rethrows -> T {
            Legacy.lock.lock()
            defer { Legacy.lock.unlock() }
            var allowed: DarwinBoolean = true
            SecKeychainGetUserInteractionAllowed(&allowed)
            SecKeychainSetUserInteractionAllowed(false)
            defer { SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
            return try work()
        }

        @available(macOS, deprecated: 10.10)
        func remove(_ found: CFTypeRef) -> OSStatus {
            guard CFGetTypeID(found) == SecKeychainItemGetTypeID() else { return errSecItemNotFound }
            return SecKeychainItemDelete(found as! SecKeychainItem)
        }
    }
}
