import Darwin
import Foundation
import os
import Security

/// What the app asks the restore daemon. The daemon is the run tool as root, registered with
/// `SMAppService.daemon` only while the owner restores this Mac from a backup. It takes
/// messages only from the app, which macOS checks by the code signature, and each message that
/// reads the backups or changes something carries the app's authorization for
/// `Identity.restoreRight`, which an administrator gave by authenticating. Token, key and
/// passphrase only ever travel in these messages and from the daemon to the client on
/// descriptors; nothing of them is written down.
@objc public protocol RestoreProtocol {
    /// The snapshots that hold the home folder of the user who asks, newest first, as
    /// `RestoreChoices` in JSON. `request` is a `RestoreRequest` in JSON, without a snapshot.
    func snapshots(_ request: Data, authorization: Data, reply: @escaping (Data?, String?) -> Void)
    /// Starts restoring the home folder of the user who asks from the request's snapshot. It
    /// takes the place of the home folder once that user has logged out. Answers with an error
    /// as a sentence, or nil once the restore has begun.
    func start(_ request: Data, authorization: Data, reply: @escaping (String?) -> Void)
    /// The `RestoreState` in JSON, or nil when no restore is under way or done.
    func status(reply: @escaping (Data?) -> Void)
    /// After the swap: removes the home folder that was set aside. Before it: gives up the
    /// restore and removes what was restored. Answers with an error as a sentence, or nil.
    func finish(authorization: Data, reply: @escaping (String?) -> Void)
}

public struct RestoreRequest: Codable {
    public var repository: String
    public var namespace: String
    public var fingerprint: String?
    public var token: String
    /// The key file, as the recovery copy has it.
    public var key: Data
    /// For a key file that is locked with one.
    public var passphrase: String?
    public var snapshot: String?

    public init(repository: String, namespace: String, fingerprint: String?, token: String, key: Data,
                passphrase: String?, snapshot: String? = nil) {
        self.repository = repository; self.namespace = namespace; self.fingerprint = fingerprint
        self.token = token; self.key = key; self.passphrase = passphrase; self.snapshot = snapshot
    }

    var client: Client {
        var config = Config(repository: repository, namespace: namespace, backupID: "", sources: [])
        config.fingerprint = fingerprint
        return Client(config: config, token: Data(token.utf8), key: key, keyPassphrase: passphrase.map { Data($0.utf8) })
    }
}

public struct RestoreChoices: Codable {
    /// The archive that holds the home folder, `<name>.pxar`.
    public let archive: String
    public let snapshots: [Client.Snapshot]
}

public struct RestoreState: Codable, Equatable {
    public enum Phase: String, Codable {
        /// The client restores the archive next to the home folder.
        case restoring
        /// The restored folder is complete and takes the place of the home folder once its
        /// owner has logged out.
        case waitingForLogout
        /// The restored folder is the home folder; the one before is set aside.
        case done
        case failed
    }

    public var phase: Phase
    public var user: String
    public var uid: UInt32
    public var home: String
    public var snapshot: String
    public var archive: String
    /// From 0 to 1, while restoring.
    public var progress: Double?
    public var message: String?
    public var notes: [String] = []
    public init(phase: Phase, user: String, uid: UInt32, home: String, snapshot: String, archive: String,
                progress: Double? = nil, message: String? = nil, notes: [String] = []) {
        self.phase = phase; self.user = user; self.uid = uid; self.home = home; self.snapshot = snapshot
        self.archive = archive; self.progress = progress; self.message = message; self.notes = notes
    }

    public var restored: String { home + ".restored" }
    public var aside: String { home + ".before-restore" }
}

public final class RestoreService: NSObject, NSXPCListenerDelegate, RestoreProtocol, @unchecked Sendable {
    /// Where the daemon keeps the state of a restore, so that it outlasts a restart. No secret is in it.
    static var stateFile: URL {
        URL(fileURLWithPath: "/Library/Application Support").appendingPathComponent(Identity.bundleID)
            .appendingPathComponent("restore.json")
    }

    private let log = Logger(subsystem: Identity.bundleID, category: "restore")
    private let lock = NSLock()
    private var current: RestoreState?

    /// What launchd starts for `Identity.restoreLabel`: answers the app until launchd stops it.
    public static func serve() -> Never {
        defineRight()
        let service = RestoreService()
        service.resume()
        let listener = NSXPCListener(machServiceName: Identity.restoreLabel)
        listener.delegate = service
        listener.resume()
        withExtendedLifetime((service, listener)) { dispatchMain() }
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Root takes messages from its own developer's app only: a build that nobody signed
        // has no developer to ask for, so it takes none.
        guard case .team = Signature.own, HelperConnection.restrict(connection, to: Identity.bundleID) else { return false }
        connection.exportedInterface = NSXPCInterface(with: RestoreProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    // MARK: - Messages

    public func snapshots(_ request: Data, authorization: Data, reply: @escaping (Data?, String?) -> Void) {
        do {
            try RestoreService.check(authorization)
            let request = try JSONDecoder().decode(RestoreRequest.self, from: request)
            let account = try caller()
            let archive = Config.archiveName(for: account.home.path)
            let snapshots = try request.client.snapshots(group: nil).filter { $0.archives.contains(archive) }
            reply(try JSONEncoder.iso8601.encode(RestoreChoices(archive: archive, snapshots: snapshots)), nil)
        } catch {
            reply(nil, "\(error)")
        }
    }

    public func start(_ request: Data, authorization: Data, reply: @escaping (String?) -> Void) {
        do {
            try RestoreService.check(authorization)
            let request = try JSONDecoder().decode(RestoreRequest.self, from: request)
            let account = try caller()
            let archive = Config.archiveName(for: account.home.path)
            guard let name = request.snapshot else { throw Failure(description: "No snapshot was chosen.") }
            let client = request.client
            let snapshot = try HomeRestore.choose(from: client.snapshots(group: nil), archive: archive, requested: name, group: nil)
            var state = RestoreState(phase: .restoring, user: account.name, uid: account.uid, home: account.home.path,
                                     snapshot: snapshot.name, archive: archive)
            try lock.withLock {
                if let current, current.phase != .failed {
                    throw Failure(description: "A restore of \(current.user)'s home folder is under way or not finished yet.")
                }
                try RestoreService.preflight(state, size: snapshot.size)
                current = state
                save()
            }
            log.notice("restoring \(archive, privacy: .public) from \(snapshot.name, privacy: .public) for uid \(account.uid)")
            reply(nil)
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do {
                    try HomeRestore.restore(client, snapshot: snapshot.name, archive: archive,
                                            into: URL(fileURLWithPath: state.restored)) { output in
                        if let progress = RestoreService.progress(in: output) { update { $0.progress = progress } }
                    }
                    state.notes = HomeRestore.adapt(URL(fileURLWithPath: state.restored), to: account)
                    update { $0.phase = .waitingForLogout; $0.progress = 1; $0.notes = state.notes }
                    waitForLogout()
                } catch {
                    log.error("restore failed: \(String(describing: error), privacy: .public)")
                    update { $0.phase = .failed; $0.message = "\(error)" }
                }
            }
        } catch {
            reply("\(error)")
        }
    }

    public func status(reply: @escaping (Data?) -> Void) {
        let state = lock.withLock { current }
        reply(state.flatMap { try? JSONEncoder.iso8601.encode($0) })
    }

    public func finish(authorization: Data, reply: @escaping (String?) -> Void) {
        do {
            try RestoreService.check(authorization)
            try lock.withLock {
                guard let state = current else { return }
                switch state.phase {
                case .restoring:
                    throw Failure(description: "The restore is still running.")
                case .waitingForLogout, .failed:
                    removeRestored(URL(fileURLWithPath: state.restored))
                case .done:
                    removeRestored(URL(fileURLWithPath: state.aside))
                }
                current = nil
                try? FileManager.default.removeItem(at: RestoreService.stateFile)
            }
            reply(nil)
        } catch {
            reply("\(error)")
        }
    }

    // MARK: - The swap

    /// Waits until the owner of the restored folder has logged out, ends what macOS keeps running
    /// for them, and lets the restored folder take the place of their home folder. A login in
    /// between puts it off until the next logout.
    private func waitForLogout() {
        while let state = lock.withLock({ current }), state.phase == .waitingForLogout {
            if !HomeRestore.isLoggedIn(state.user), HomeRestore.endBackgroundSession(uid: state.uid), !HomeRestore.isLoggedIn(state.user) {
                do {
                    try HomeRestore.swap(home: URL(fileURLWithPath: state.home), restored: URL(fileURLWithPath: state.restored),
                                         aside: URL(fileURLWithPath: state.aside))
                    log.notice("the restored home folder of uid \(state.uid) is in place")
                    update { $0.phase = .done }
                } catch {
                    log.error("swap failed: \(String(describing: error), privacy: .public)")
                    update { $0.phase = .failed; $0.message = "\(error)" }
                }
                return
            }
            sleep(2)
        }
    }

    /// After a restart: a restore that was running is gone with the client and is cleared away;
    /// one that waited for the logout waits again.
    private func resume() {
        guard let data = try? Data(contentsOf: RestoreService.stateFile),
              var state = try? JSONDecoder.iso8601.decode(RestoreState.self, from: data) else { return }
        if state.phase == .restoring {
            removeRestored(URL(fileURLWithPath: state.restored))
            state.phase = .failed
            state.message = "The Mac restarted while the home folder was being restored. Start the restore again."
        }
        lock.withLock { current = state; save() }
        if state.phase == .waitingForLogout { DispatchQueue.global().async { self.waitForLogout() } }
    }

    private func update(_ change: (inout RestoreState) -> Void) {
        lock.withLock {
            guard var state = current else { return }
            change(&state)
            current = state
            save()
        }
    }

    /// With the lock held.
    private func save() {
        let folder = RestoreService.stateFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let current else { try? FileManager.default.removeItem(at: RestoreService.stateFile); return }
        try? JSONEncoder.iso8601.encode(current).write(to: RestoreService.stateFile, options: .atomic)
    }

    // MARK: - Checks

    /// The user whose app sent the message being answered.
    private func caller() throws -> HomeRestore.Account {
        guard let connection = NSXPCConnection.current() else { throw Failure(description: "No one asked.") }
        let uid = connection.effectiveUserIdentifier
        guard uid != 0, let entry = getpwuid(uid) else { throw Failure(description: "The home folder of root is not restored.") }
        return try HomeRestore.account(String(cString: entry.pointee.pw_name))
    }

    /// What has to hold before anything is restored.
    static func preflight(_ state: RestoreState, size: Int64?) throws {
        for path in [state.restored, state.aside] where FileManager.default.fileExists(atPath: path) {
            throw Failure(description: "\(path) is there already, from an earlier restore. Move it out of the way first.")
        }
        // Without Full Disk Access macOS does not let even root into a home folder, nor move it.
        guard opendir(state.home + "/Documents").map({ closedir($0); return true }) ?? (errno == ENOENT) else {
            throw Failure(description: "PBS Mackup needs Full Disk Access to put a home folder in place. Turn it on in System Settings, then restore again.")
        }
        if let size, let free = HomeRestore.freeBytes(at: URL(fileURLWithPath: "/Users")), free < size + size / 10 {
            throw Failure(description: "The snapshot takes \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)), "
                + "and the disk has \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free.")
        }
    }

    /// The last "progress 22% (...)" in what the client wrote.
    static func progress(in output: Data) -> Double? {
        let text = String(decoding: output, as: UTF8.self)
        guard let found = text.range(of: "progress ", options: .backwards) else { return nil }
        let digits = text[found.upperBound...].prefix { $0.isASCII && $0.isNumber }
        guard text[found.upperBound...].dropFirst(digits.count).hasPrefix("%"), let percent = Double(digits) else { return nil }
        return percent / 100
    }

    // MARK: - Authorization

    /// What `Identity.restoreRight` takes: an administrator authenticates, and that holds for
    /// five minutes in the authorization the app made, long enough to go from finding the
    /// backups to starting the restore. Not shared with other authorizations. macOS's own rule
    /// `authenticate-admin` holds for no time at all, so the daemon, which may not ask, would
    /// find it expired by the time the message arrives.
    static let rightDefinition: [String: Any] = [
        "class": "user", "group": "admin", "timeout": 300, "shared": false, "allow-root": false,
        "authenticate-user": true, "session-owner": false,
    ]

    /// Puts `Identity.restoreRight` into the authorization database when it is not there, or
    /// when it is the one a development build wrote, which pointed at `authenticate-admin`. An
    /// administrator can change the rule with `security authorizationdb`, and theirs is kept.
    static func defineRight() {
        var stored: CFDictionary?
        if AuthorizationRightGet(Identity.restoreRight, &stored) == errAuthorizationSuccess {
            let rule = (stored as? [String: Any])?["rule"] as? [String]
            guard rule == ["authenticate-admin"] else { return }
        }
        var reference: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &reference) == errAuthorizationSuccess, let reference else { return }
        defer { AuthorizationFree(reference, []) }
        AuthorizationRightSet(reference, Identity.restoreRight, rightDefinition as CFDictionary,
                              "PBS Mackup wants to restore your home folder from a backup." as CFString, nil, nil)
    }

    /// Throws unless `external`, the external form of an authorization the app made, has the
    /// right to restore a home folder. Nobody is asked here: the app asked when it made it.
    /// What a message without the administrator's yes is answered with.
    public static let refused = "An administrator has to allow the restore."

    static func check(_ external: Data) throws {
        let refused = Failure(description: RestoreService.refused)
        guard external.count == MemoryLayout<AuthorizationExternalForm>.size else { throw refused }
        var form = AuthorizationExternalForm()
        _ = withUnsafeMutableBytes(of: &form) { external.copyBytes(to: $0) }
        var reference: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&form, &reference) == errAuthorizationSuccess, let reference else { throw refused }
        defer { AuthorizationFree(reference, []) }
        guard RestoreAuthorization.copyRight(reference, interactive: false) else { throw refused }
    }
}

/// The app's side of the right to restore a home folder. The external form the daemon checks
/// is only good while this authorization lives, so the app keeps it for as long as it restores.
public final class RestoreAuthorization: @unchecked Sendable {
    private let reference: AuthorizationRef
    /// What goes with each message to the daemon.
    public let externalForm: Data

    /// Has an administrator authenticate for `Identity.restoreRight`. Blocks while macOS asks,
    /// so it is made away from the main thread. Throws when the administrator says no.
    public init() throws {
        var made: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &made) == errAuthorizationSuccess, let made else {
            throw Failure(description: "macOS could not ask for an administrator.")
        }
        guard RestoreAuthorization.copyRight(made, interactive: true) else {
            AuthorizationFree(made, [])
            throw Failure(description: "An administrator has to allow the restore.")
        }
        var form = AuthorizationExternalForm()
        guard AuthorizationMakeExternalForm(made, &form) == errAuthorizationSuccess else {
            AuthorizationFree(made, [])
            throw Failure(description: "macOS could not hand on the authorization.")
        }
        reference = made
        externalForm = withUnsafeBytes(of: form) { Data($0) }
    }

    deinit { AuthorizationFree(reference, [.destroyRights]) }

    static func copyRight(_ reference: AuthorizationRef, interactive: Bool) -> Bool {
        Identity.restoreRight.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { items in
                var rights = AuthorizationRights(count: 1, items: items)
                let flags: AuthorizationFlags = interactive ? [.extendRights, .interactionAllowed] : [.extendRights]
                return AuthorizationCopyRights(reference, &rights, nil, flags, nil) == errAuthorizationSuccess
            }
        }
    }
}
