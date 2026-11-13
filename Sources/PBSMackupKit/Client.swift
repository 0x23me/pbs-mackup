import Foundation
import Security

/// Starts the embedded `proxmox-backup-client` with the repository, the token and the key.
/// Secrets never go into the arguments or the environment, which any program of the user can
/// read off a running client: the key arrives on standard input (`--keyfd 0`), the token on a
/// descriptor of its own (`PBS_PASSWORD_FD`).
public struct Client {
    public typealias Failure = PBSMackupKit.Failure

    public let config: Config
    private let token: Data
    private let key: Data

    /// `needsKey: false` is for the connection check during setup, before a key exists.
    public init(config: Config, needsKey: Bool = true) throws {
        try self.init(config: config, token: nil, needsKey: needsKey)
    }

    /// `token` stands in for the stored one, to try a new token before it is kept; see `accept`.
    private init(config: Config, token: Data?, needsKey: Bool) throws {
        guard let token = try token ?? Keychain.get(.token) else {
            throw Failure(description: "The API token is not in the Keychain.")
        }
        // Where no key is needed none is fetched, so none can be handed on by mistake.
        guard let key = try needsKey ? Keychain.get(.encryptionKey) : Data() else {
            throw Failure(description: "The encryption key is not in the Keychain.")
        }
        // A key that some other program put into the Keychain would encrypt the backups for
        // that program and not for the owner.
        guard !needsKey || Seal.holds(key: key) else { throw Failure(description: Seal.keyChanged) }
        self.config = config
        self.token = token
        self.key = key
    }

    public var executable: URL { Client.executable(clientPath: config.clientPath) }

    /// The client to run. A release build only ever runs the one in the app bundle, whatever
    /// the configuration and the environment say. A development build takes the configured
    /// one, the one in the app bundle, the one named in `PBS_MACKUP_CLIENT`, or the one built in
    /// a checkout next to this one.
    public static func executable(clientPath: String?) -> URL {
        // Not argv[0]: launchd starts the tool with a path relative to the bundle.
        let tool = Bundle.main.executableURL?.resolvingSymlinksInPath() ?? URL(fileURLWithPath: ".")
        let bundled = tool.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Helpers/proxmox-backup-client")
        #if DEBUG
        if let path = clientPath { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        if let path = ProcessInfo.processInfo.environment["PBS_MACKUP_CLIENT"] { return URL(fileURLWithPath: path) }
        // .build/debug/pbs-mackup-run: three levels up is the checkout.
        let checkout = tool.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return checkout.deletingLastPathComponent()
            .appendingPathComponent("proxmox-backup-macos/native-target/release/proxmox-backup-client")
        #else
        return bundled
        #endif
    }

    /// The client for `mount`: a second copy next to the first, the only one that may load
    /// FUSE-T's library. Where there is none (a development build) it is the client itself.
    var mountExecutable: URL {
        let copy = executable.deletingLastPathComponent().appendingPathComponent("proxmox-backup-client-mount")
        return FileManager.default.isExecutableFile(atPath: copy.path) ? copy : executable
    }

    /// What every client starts with, built from scratch: no variable the tool inherited is
    /// handed on to the client, where it could name another server or a proxy, other trusted
    /// roots, or a command to run. The home folder, the user and the temporary folder are the
    /// ones the app itself uses; with `PBS_MACKUP_HOME` the client keeps its files there too.
    static func environment(inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = ["HOME": (Paths.override ?? Paths.home).path, "USER": NSUserName(), "LOGNAME": NSUserName(),
                           "TMPDIR": NSTemporaryDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        environment["LANG"] = inherited["LANG"]
        // The client's OpenSSL looks for the trusted roots and for its settings where Homebrew
        // keeps them, a folder any program of the user can write to. It gets the roots macOS
        // ships and no settings, which is also what it finds on a Mac without Homebrew.
        environment["SSL_CERT_FILE"] = "/etc/ssl/cert.pem"
        environment["SSL_CERT_DIR"] = "/etc/ssl/certs"
        environment["OPENSSL_CONF"] = "/dev/null"
        #if DEBUG
        // The tests' stand-in client reads these.
        for (name, value) in inherited where name.hasPrefix("PBS_MACKUP_") { environment[name] = value }
        #endif
        return environment
    }

    /// Starts the client. `--ns` is added, and `--keyfd 0` unless `usesKey` is false (not every
    /// command takes a key). With `mergingErrors` its standard error arrives with its standard
    /// output. A release build only starts a client of its own developer.
    public func start(_ arguments: [String], usesKey: Bool = true, mergingErrors: Bool = false) throws -> Child {
        try start(arguments, usesKey: usesKey, mergingErrors: mergingErrors, executable: executable, signedAs: Client.requirement())
    }

    /// What a client has to meet: signed by the developer who signed this program, as the
    /// client (the developer's other programs are not clients) and, unless it is the copy for
    /// `mount`, not allowed to load libraries of other developers. That copy is, for FUSE-T's
    /// library, and so was the only client of earlier versions of the app: put in the place
    /// of today's, either would do every backup with whatever library lies where it looks for
    /// one. Nil when nothing is asked, which is in a development build (it runs stand-in
    /// clients) and in a build no developer signed.
    static func requirement(mounting: Bool = false) throws -> SecRequirement? {
        #if DEBUG
        return nil
        #else
        switch Signature.own {
        case .team(let team):
            let identifier = Identity.bundleID + (mounting ? ".client-mount" : ".client")
            if let signed = Signature.requirement(team: team, identifier: identifier),
               let requirement = mounting ? signed : Signature.withoutForeignLibraries(signed) { return requirement }
        case .nobody:
            return nil
        case .unknown:
            break
        }
        throw Failure(description: "This program no longer matches its own signature, so it starts no client. Install the app again.")
        #endif
    }

    /// How many files this program and the clients it starts may have open, set once. In a
    /// backup that builds on an earlier one, the client keeps the files it has looked at open
    /// until it knows what to do with them, as many as the limits allow: the hard limit less
    /// half the soft one. launchd starts a job with a soft limit of 256 and no hard limit at
    /// all, which the client takes for room without end, until macOS's own limit (some
    /// 120,000 files) ends the backup with "Too many open files". With both limits at 8192 it
    /// keeps 4096 open. A hard limit that is lower already stays as it is.
    static let openFiles: rlim_t = {
        var limit = rlimit()
        getrlimit(RLIMIT_NOFILE, &limit)
        if limit.rlim_max > 8192 {
            limit = rlimit(rlim_cur: 8192, rlim_max: 8192)
            setrlimit(RLIMIT_NOFILE, &limit)
        }
        getrlimit(RLIMIT_NOFILE, &limit)
        return limit.rlim_max
    }()

    /// With a `requirement`, the client's file has to meet it before the client is started,
    /// and the started program has to meet it before it gets the token and the key: the file
    /// can be exchanged in between, what runs cannot. Until then the client has neither, so
    /// the token is as safe as the key.
    func start(_ arguments: [String], usesKey: Bool = true, mergingErrors: Bool = false, executable: URL,
               signedAs requirement: SecRequirement?) throws -> Child {
        if let requirement, !Signature.isSigned(executable, as: requirement) {
            throw Failure(description: "\(executable.path) is not signed the way this app's developer signs its client, so it was not started. Install the app again.")
        }
        _ = Client.openFiles
        var environment = Client.environment()
        environment["PBS_REPOSITORY"] = config.repository
        environment["PBS_PASSWORD_FD"] = "3"
        environment["PBS_FINGERPRINT"] = config.fingerprint
        // The client takes the first line of what it reads from the descriptor.
        let secret = String(decoding: token, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        var input: [Int32: Data] = [3: Data(secret.utf8)]
        // A command that takes no key gets none: its standard input is empty.
        if usesKey { input[0] = key }
        let child = try Child(executable, arguments + ["--ns", config.namespace] + (usesKey ? ["--keyfd", "0"] : []),
                              environment: environment, input: input, mergingErrors: mergingErrors, sendingInput: false)
        if let requirement {
            guard let client = Signature.running(child.pid), Signature.isSigned(client, as: requirement) else {
                child.closeInput()
                // One that ended by itself got neither, and says why in its own words.
                guard child.isRunning else { return child }
                child.signal(SIGKILL)
                child.wait()
                throw Failure(description: "The client that started is not signed the way this app's developer signs its client. It was stopped before it got the token or the key.")
            }
        }
        child.sendInput()
        return child
    }

    /// Runs to completion; returns standard output, or throws with the client's last error line.
    public func capture(_ arguments: [String], usesKey: Bool = true) throws -> Data {
        try capture(start(arguments, usesKey: usesKey))
    }

    func capture(_ child: Child) throws -> Data {
        let result = child.finish()
        guard result.status == 0 else { throw Client.failure(status: result.status, errors: result.errors) }
        return result.output
    }

    /// Runs to completion and hands standard output to `take` as it arrives; throws as `capture` does.
    func stream(_ arguments: [String], to take: (Data) -> Void) throws {
        let result = try start(arguments).finish(output: take)
        guard result.status == 0 else { throw Client.failure(status: result.status, errors: result.errors) }
    }

    /// What a client that failed said last: its `Error:` line, or its last line.
    private static func failure(status: Int32, errors: Data) -> Failure {
        let lines = String(decoding: errors, as: UTF8.self).split(separator: "\n")
        let stated = lines.last(where: { $0.hasPrefix("Error: ") }).map { String($0.dropFirst(7)) }
        return Failure(description: stated ?? lines.last.map(String.init) ?? "The client exited with status \(status).")
    }

    /// Fails with the server's error when the repository, the namespace or the token is wrong.
    public func checkConnection() throws {
        _ = try capture(["snapshot", "list", "host/\(config.backupID)", "--output-format", "json"], usesKey: false)
    }

    /// Lets the server judge a configuration that is not stored yet, with a new token when one
    /// is given and the stored one otherwise (`token` nil or empty). Only when the server
    /// accepts is the token put into the Keychain and the configuration saved; when it does
    /// not, this throws and both stay as they were. Needs no encryption key.
    public static func accept(_ candidate: Config, token: Data? = nil) throws {
        let token = token.flatMap { $0.isEmpty ? nil : $0 }
        try Client(config: candidate, token: token, needsKey: false).checkConnection()
        guard let token else { return try candidate.save() }
        let previous = try Keychain.get(.token)
        try Keychain.set(.token, token)
        do { try candidate.save() } catch {
            // Both or neither: the stored configuration was not checked with the new token.
            if let previous { try? Keychain.set(.token, previous) }
            throw error
        }
    }

    // MARK: - Names

    /// PBS's rule for a backup id and for an archive name: letters, digits, `.`, `_` and `-`,
    /// the first neither `.` nor `-`.
    private static let safeID = "[A-Za-z0-9_][A-Za-z0-9._-]*"

    /// Whether `name` is the snapshot of a host as the client takes it, `host/<id>/<time>` with
    /// the time as `2026-11-12T14:00:05Z`. Snapshot and archive names come from the server and
    /// from the command line and become arguments of the client and parts of paths in the
    /// cache, so whatever is not such a name is turned away, here and in `isArchive`.
    public static func isSnapshot(_ name: String) -> Bool {
        matches(name, "host/\(safeID)/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")
    }

    /// Whether `name` is a folder archive: `<folder>.pxar`, the folder by the rule for an id
    /// and without `..`.
    public static func isArchive(_ name: String) -> Bool {
        matches(name, safeID + "\\.pxar") && !name.contains("..")
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        // Not `$`: that also matches before a line break at the end.
        text.range(of: "\\A(?:\(pattern))\\z", options: .regularExpression) != nil
    }

    /// Throws unless these are names; what `list`, `restore` and the others are given.
    static func check(snapshot: String? = nil, archives: [String]) throws {
        if let snapshot, !isSnapshot(snapshot) {
            throw Failure(description: "“\(snapshot)” is not a snapshot: it should look like host/my-mac/2026-11-12T14:00:05Z.")
        }
        if let archive = archives.first(where: { !isArchive($0) }) {
            throw Failure(description: "“\(archive)” is not an archive: it should look like Documents.pxar.")
        }
    }

    /// A path inside an archive as an argument for the client. The client takes an argument
    /// that begins with `-` for an option, also after `--`, and a file can be called
    /// `-repository=...`. With a slash in front it is a path whatever it is called; the client
    /// drops the slash.
    static func pathArgument(_ path: String) -> String { "/" + path }

    // MARK: - Browsing and restoring

    public struct Snapshot: Codable, Equatable, Identifiable {
        public var id: String { name }
        /// `host/<id>/<time>`, as the client takes it.
        public let name: String
        public let time: Date
        /// The archives a snapshot holds, as `<folder>.pxar`.
        public let archives: [String]
        public let size: Int64?
    }

    public struct Entry: Codable, Equatable, Identifiable {
        public var id: String { name }
        public let name: String
        public let type: String
        public let mtime: Int64
        public let size: Int64?
        public var isDirectory: Bool { type == "directory" }
        public init(name: String, type: String, mtime: Int64, size: Int64?) {
            self.name = name; self.type = type; self.mtime = mtime; self.size = size
        }
    }

    /// The snapshots of this Mac's backup group, newest first. What the server lists under a
    /// name that is not a snapshot's or an archive's is left out.
    public func snapshots() throws -> [Snapshot] {
        struct Raw: Decodable {
            struct File: Decodable { let filename: String }
            let backupType: String, backupID: String, backupTime: Int64
            let files: [File]
            let size: Int64?
            enum CodingKeys: String, CodingKey {
                case backupType = "backup-type", backupID = "backup-id", backupTime = "backup-time", files, size
            }
        }
        let data = try capture(["snapshot", "list", "host/\(config.backupID)", "--output-format", "json"], usesKey: false)
        let formatter = ISO8601DateFormatter()
        return try JSONDecoder().decode([Raw].self, from: data).compactMap { raw -> Snapshot? in
            let time = Date(timeIntervalSince1970: TimeInterval(raw.backupTime))
            let name = "\(raw.backupType)/\(raw.backupID)/\(formatter.string(from: time))"
            guard Client.isSnapshot(name) else { return nil }
            return Snapshot(name: name, time: time, archives: Client.archives(in: raw.files.map(\.filename)), size: raw.size)
        }.sorted { $0.time > $1.time }
    }

    /// The folder archives among a snapshot's files; the port's own attribute archives are left out.
    static func archives(in files: [String]) -> [String] {
        files.compactMap { file -> String? in
            for suffix in [".mpxar.didx", ".pxar.didx"] where file.hasSuffix(suffix) {
                let base = String(file.dropLast(suffix.count))
                return base.hasPrefix("native-macos-payloads") ? nil : base + ".pxar"
            }
            return nil
        }.filter(isArchive).sorted()
    }

    /// One directory of an archive; `path` is relative to the archive root, empty for the root.
    public func list(snapshot: String, archive: String, path: String) throws -> [Entry] {
        try Client.check(snapshot: snapshot, archives: [archive])
        let data = try capture(["catalog", "list", snapshot, archive, Client.pathArgument(path)])
        return try JSONDecoder().decode([Entry].self, from: data)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A state of one file that differs from the one before it in size or modification date.
    public struct Version: Codable, Equatable, Identifiable {
        public var id: String { snapshot }
        /// The oldest snapshot that holds this state; restoring from it gives this version.
        public let snapshot: String
        public let backedUp: Date
        public let modified: Int64
        public let size: Int64?
    }

    /// The versions of one item across the snapshots, newest first: one row per change, not one
    /// per snapshot. `path` is relative to the archive root.
    public func versions(archive: String, path: String) throws -> [Version] {
        try Client.check(archives: [archive])
        let parent = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
        let snapshots = try snapshots().filter { $0.archives.contains(archive) }
        var entries = [Entry?](repeating: nil, count: snapshots.count)
        var failure: Error?
        let lock = NSLock()
        // One client per snapshot, a few at a time.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        for (index, snapshot) in snapshots.enumerated() {
            queue.addOperation {
                let listed = Result { try self.list(snapshot: snapshot.name, archive: archive, path: parent) }
                lock.lock(); defer { lock.unlock() }
                switch listed {
                case .success(let found): entries[index] = found.first { $0.name == name }
                // A snapshot from before the item's folder existed simply has no version of it.
                // Anything else, a server that went away say, would leave versions out unseen.
                case .failure(let error): if !Client.isMissingPath(error) { failure = failure ?? error }
                }
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        if let failure { throw failure }
        return Client.versions(in: Array(zip(snapshots, entries)))
    }

    /// Whether the client failed because the snapshot has nothing at the path it was asked
    /// for. The client says so in words only, so this is the one place that reads them.
    public static func isMissingPath(_ error: Error) -> Bool { "\(error)".contains("no such path") }

    /// `seen` is newest first, as `snapshots()` returns them.
    static func versions(in seen: [(snapshot: Snapshot, entry: Entry?)]) -> [Version] {
        var versions: [Version] = []
        for (snapshot, entry) in seen.reversed() {
            guard let entry else { continue }
            if let last = versions.last, last.modified == entry.mtime, last.size == entry.size { continue }
            versions.append(Version(snapshot: snapshot.name, backedUp: snapshot.time, modified: entry.mtime, size: entry.size))
        }
        return versions.reversed()
    }

    /// What to do when the folder already has an item of that name.
    public enum Conflict: String {
        /// The restored item gets a numbered name; the existing one stays as it is.
        case keepBoth = "keep-both"
        /// The existing item is replaced, once the restored one is complete.
        case replace
        /// Nothing is restored.
        case skip
    }

    /// Restores one file or folder into `folder` and returns where it ended up, or nil when it
    /// was skipped. An existing item is only ever touched with `.replace`, and only after the
    /// restored one has arrived completely.
    public func restore(snapshot: String, archive: String, path: String, into folder: URL,
                        conflict: Conflict = .keepBoth) throws -> URL? {
        try Client.check(snapshot: snapshot, archives: [archive])
        let path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else { throw Failure(description: "Nothing selected to restore.") }
        let name = (path as NSString).lastPathComponent
        let existing = folder.appendingPathComponent(name)
        let taken = exists(existing)
        if taken && conflict == .skip { return nil }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The client gives the staging folder the metadata of the archive's root folder.
        let staging = folder.appendingPathComponent(".pbs-mackup-restore-\(UUID().uuidString)")
        var keepStaging = false
        defer { if !keepStaging { removeRestored(staging) } }
        // Not `restore --pattern`: that reads the whole archive to find one item.
        _ = try capture(["catalog", "extract", snapshot, archive, Client.pathArgument(path), staging.path])
        let restored = staging.appendingPathComponent(name)
        guard exists(restored) else { throw Failure(description: "The snapshot has no \(path).") }
        if taken && conflict == .replace {
            // Not replaceItemAt: that keeps metadata of the item it replaces. The old item steps
            // aside into the staging folder and goes away with it; if the restored one cannot
            // take its place, the old one comes back.
            let aside = staging.appendingPathComponent("replaced-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: existing, to: aside)
            do { try Client.move(restored, to: existing) } catch let failure {
                do { try FileManager.default.moveItem(at: aside, to: existing) } catch {
                    // The item that was there is in the staging folder now, so that one stays.
                    keepStaging = true
                    throw Failure(description: "\(name) could not be replaced (\(failure.localizedDescription)), and the item "
                        + "that was there could not be put back. It is at \(aside.path).")
                }
                throw failure
            }
            return existing
        }
        let destination = Client.freeName(for: name, in: folder)
        try Client.move(restored, to: destination)
        return destination
    }

    /// Moves a restored item to where it belongs. A locked item (Finder's Locked) cannot be
    /// renamed, and the client restores the lock with the item: it comes off for the move and
    /// goes back on after it.
    static func move(_ item: URL, to destination: URL) throws {
        var info = stat()
        let locks = UInt32(UF_IMMUTABLE | UF_APPEND)
        let locked = lstat(item.path, &info) == 0 && info.st_flags & locks != 0
        if locked { lchflags(item.path, info.st_flags & ~locks) }
        do { try FileManager.default.moveItem(at: item, to: destination) } catch {
            if locked { lchflags(item.path, info.st_flags) }
            throw error
        }
        if locked { lchflags(destination.path, info.st_flags) }
    }

    /// `name`, or `name 2`, `name 3`, ... before the extension, whichever is not taken in `folder`.
    static func freeName(for name: String, in folder: URL) -> URL {
        var candidate = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var number = 2
        while exists(candidate) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }
}

extension Signature {
    /// What `signed` asks, and that the program is without the entitlement that lets it load
    /// libraries its own developer did not sign.
    static func withoutForeignLibraries(_ signed: SecRequirement) -> SecRequirement? {
        var text: CFString?
        guard SecRequirementCopyString(signed, [], &text) == errSecSuccess, let text else { return nil }
        return requirement("(\(text)) and ! entitlement[\"com.apple.security.cs.disable-library-validation\"] exists")
    }
}
