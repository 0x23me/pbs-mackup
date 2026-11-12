import Foundation

/// Starts the embedded `proxmox-backup-client` with the repository, the token and the key.
/// Secrets never go into the arguments: the key arrives on standard input (`--keyfd 0`), the
/// token in the environment of the client only.
public struct Client {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        public init(description: String) { self.description = description }
    }

    public let config: Config
    private let token: Data
    private let key: Data

    /// `needsKey: false` is for the connection check during setup, before a key exists.
    public init(config: Config, needsKey: Bool = true) throws {
        guard let token = try Keychain.get(.token) else {
            throw Failure(description: "The API token is not in the Keychain.")
        }
        guard let key = try Keychain.get(.encryptionKey) ?? (needsKey ? nil : Data()) else {
            throw Failure(description: "The encryption key is not in the Keychain.")
        }
        self.config = config
        self.token = token
        self.key = key
    }

    public var executable: URL { Client.executable(clientPath: config.clientPath) }

    /// The client to run: the configured one, the one in the app bundle, or for a development
    /// build the one named in `PBS_MACKUP_CLIENT` or built in a checkout next to this one.
    public static func executable(clientPath: String?) -> URL {
        if let path = clientPath { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        // Not argv[0]: launchd starts the tool with a path relative to the bundle.
        if let tool = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let bundled = tool.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Helpers/proxmox-backup-client")
            if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        }
        if let path = ProcessInfo.processInfo.environment["PBS_MACKUP_CLIENT"] { return URL(fileURLWithPath: path) }
        // .build/debug/pbs-mackup-run: three levels up is the checkout.
        let checkout = (Bundle.main.executableURL?.resolvingSymlinksInPath() ?? URL(fileURLWithPath: "."))
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return checkout.deletingLastPathComponent()
            .appendingPathComponent("proxmox-backup-macos/native-target/release/proxmox-backup-client")
    }

    /// A client process ready to run. `--ns` is added, and `--keyfd 0` unless `usesKey` is false
    /// (not every command takes a key); call `start` to run it.
    public func process(_ arguments: [String], usesKey: Bool = true) -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments + ["--ns", config.namespace] + (usesKey ? ["--keyfd", "0"] : [])
        var environment = ProcessInfo.processInfo.environment
        environment["PBS_REPOSITORY"] = config.repository
        environment["PBS_PASSWORD"] = String(decoding: token, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        environment["PBS_FINGERPRINT"] = config.fingerprint
        process.environment = environment
        process.standardInput = Pipe()
        return process
    }

    /// Runs the process and hands it the key.
    public func start(_ process: Process) throws {
        try process.run()
        if let input = process.standardInput as? Pipe {
            input.fileHandleForWriting.write(key)
            try? input.fileHandleForWriting.close()
        }
    }

    /// Runs to completion; returns standard output, or throws with the client's last error line.
    public func capture(_ arguments: [String], usesKey: Bool = true) throws -> Data {
        let process = process(arguments, usesKey: usesKey)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try start(process)
        var errors = Data()
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) { errors = err.fileHandleForReading.readDataToEndOfFile() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let lines = String(decoding: errors, as: UTF8.self).split(separator: "\n")
            let message = lines.last(where: { $0.hasPrefix("Error: ") }).map { String($0.dropFirst(7)) }
                ?? lines.last.map(String.init) ?? "The client exited with status \(process.terminationStatus)."
            throw Failure(description: message)
        }
        return data
    }

    /// Fails with the server's error when the repository, the namespace or the token is wrong.
    public func checkConnection() throws {
        _ = try capture(["snapshot", "list", "host/\(config.backupID)", "--output-format", "json"], usesKey: false)
    }

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

    /// The snapshots of this Mac's backup group, newest first.
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
        return try JSONDecoder().decode([Raw].self, from: data).map { raw in
            let time = Date(timeIntervalSince1970: TimeInterval(raw.backupTime))
            return Snapshot(name: "\(raw.backupType)/\(raw.backupID)/\(formatter.string(from: time))", time: time,
                            archives: Client.archives(in: raw.files.map(\.filename)), size: raw.size)
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
        }.sorted()
    }

    /// One directory of an archive; `path` is relative to the archive root, empty for the root.
    public func list(snapshot: String, archive: String, path: String) throws -> [Entry] {
        let data = try capture(["catalog", "list", snapshot, archive, path])
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
        let parent = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
        let seen = try snapshots().filter { $0.archives.contains(archive) }.map { snapshot -> (Snapshot, Entry?) in
            // A snapshot from before the item or its folder existed simply has no version of it.
            let entries = (try? list(snapshot: snapshot.name, archive: archive, path: parent)) ?? []
            return (snapshot, entries.first { $0.name == name })
        }
        return Client.versions(in: seen)
    }

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
        let path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else { throw Failure(description: "Nothing selected to restore.") }
        let existing = folder.appendingPathComponent((path as NSString).lastPathComponent)
        let taken = (try? existing.checkResourceIsReachable()) == true
        if taken && conflict == .skip { return nil }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = folder.appendingPathComponent(".pbs-mackup-restore-\(UUID().uuidString)")
        defer {
            // The client gives the staging folder the metadata of the archive's root folder,
            // and e.g. ~/Downloads carries an ACL that forbids deleting it.
            tool("/bin/chmod", ["-R", "-N", staging.path])
            tool("/usr/bin/chflags", ["-R", "nouchg", staging.path])
            try? FileManager.default.removeItem(at: staging)
        }
        // Not `restore --pattern`: that reads the whole archive to find one item.
        _ = try capture(["catalog", "extract", snapshot, archive, path, staging.path])
        let restored = staging.appendingPathComponent((path as NSString).lastPathComponent)
        guard FileManager.default.fileExists(atPath: restored.path) else {
            throw Failure(description: "The snapshot has no \(path).")
        }
        if taken && conflict == .replace {
            // Not replaceItemAt: that keeps metadata of the item it replaces. The old item steps
            // aside into the staging folder and goes away with it; if the restored one cannot
            // take its place, the old one comes back.
            let aside = staging.appendingPathComponent("replaced-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: existing, to: aside)
            do { try FileManager.default.moveItem(at: restored, to: existing) } catch {
                try? FileManager.default.moveItem(at: aside, to: existing)
                throw error
            }
            return existing
        }
        let destination = Client.freeName(for: restored.lastPathComponent, in: folder)
        try FileManager.default.moveItem(at: restored, to: destination)
        return destination
    }

    /// `name`, or `name 2`, `name 3`, ... before the extension, whichever is not taken in `folder`.
    static func freeName(for name: String, in folder: URL) -> URL {
        var candidate = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }
}
