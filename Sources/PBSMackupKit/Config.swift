import Foundation

public struct Config: Codable, Equatable {
    /// What to do when the APFS snapshot cannot be mounted, which is the case without Full Disk Access.
    public enum FrozenSnapshot: String, Codable {
        /// The run fails, so nothing is ever backed up that was not read from a snapshot.
        case required
        /// The run reads the folders as they are while it runs and says so in its record
        /// (`frozen` is false). What a new configuration starts with.
        case whenPermitted
    }

    /// As the client takes it: `user@realm!token@host[:port]:datastore`.
    public var repository: String
    public var namespace: String
    /// The backup group is `host/<backupID>`.
    public var backupID: String
    /// Absolute folders on the Data volume. Each becomes one archive named after the folder;
    /// `objection(toAdding:to:)` says which folders cannot be among them.
    public var sources: [String]
    /// The owner's own exclusions, patterns as in `.pxarexclude`. `defaultExcludes` always apply too.
    public var excludes: [String]
    public var frozenSnapshot: FrozenSnapshot
    /// A client to use instead of the one in the app bundle. Only a development build looks
    /// at it; the app as it is installed always runs the client it came with.
    public var clientPath: String?
    /// How many files to restore and compare after each backup; 20 when absent, 0 for none.
    public var sampleFiles: Int?
    /// The server's certificate fingerprint, confirmed at setup. Only set for a certificate that
    /// the client does not accept by itself: one it does accept changes at every renewal.
    public var fingerprint: String?
    /// How often a backup is made, in minutes; hourly when absent.
    public var intervalMinutes: Int?
    public var interval: Int { max(5, intervalMinutes ?? 60) }

    public init(repository: String, namespace: String, backupID: String, sources: [String],
                excludes: [String] = [], frozenSnapshot: FrozenSnapshot = .whenPermitted, clientPath: String? = nil) {
        self.repository = repository
        self.namespace = namespace
        self.backupID = backupID
        self.sources = sources
        self.excludes = excludes
        self.frozenSnapshot = frozenSnapshot
        self.clientPath = clientPath
    }

    public static func load(from url: URL = Paths.config) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
    }

    /// Writes the configuration. Written to its own place it is also noted in the seal, as
    /// the configuration to go by: only the app and the run tool save through here.
    public func save(to url: URL = Paths.config) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
        if url.standardizedFileURL == Paths.config.standardizedFileURL { try Seal.set(config: self) }
    }

    /// Left out of every backup: what macOS keeps for itself in a folder, the trash, and the
    /// caches of a home folder. A name without a slash matches at any depth; `/Library/Caches`
    /// only at the top of a backed-up folder, so it only bites when that folder is a home folder.
    public static let defaultExcludes = [".DS_Store", ".Trash", ".Trashes", ".TemporaryItems", ".Spotlight-V100",
                                         ".fseventsd", ".DocumentRevisions-V100", "/Library/Caches"]

    /// Host and port of the server named in `repository`.
    public var server: (host: String, port: Int)? {
        guard let at = repository.lastIndex(of: "@") else { return nil }
        var rest = String(repository[repository.index(after: at)...])
        var host: String
        if rest.hasPrefix("[") {                       // [v6-address]:port:datastore
            guard let close = rest.firstIndex(of: "]") else { return nil }
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            rest = String(rest[rest.index(after: close)...])
            if rest.hasPrefix(":") { rest.removeFirst() }
        } else {
            let parts = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            host = String(parts[0])
            rest = String(parts[1])
        }
        let tail = rest.split(separator: ":", omittingEmptySubsequences: false)
        if tail.count == 2, let port = Int(tail[0]) { return (host, port) }
        return host.isEmpty ? nil : (host, 8007)
    }

    /// Archive name for a source folder: its last path component, limited to what the client
    /// takes as a name, which is ASCII letters, digits, `-` and `_`. Not a `-` in front either:
    /// the client would read the name as an option.
    public static func archiveName(for source: String) -> String {
        let name = URL(fileURLWithPath: source).lastPathComponent
        var allowed = String(name.map { $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) ? $0 : "_" })
        if allowed.hasPrefix("-") { allowed = "_" + allowed.dropFirst() }
        return allowed + ".pxar"
    }

    /// The path a run reads a source under: inside the snapshot there is no /var or /tmp link,
    /// only /private/var.
    public static func realPath(_ source: String) -> String {
        let expanded = (source as NSString).expandingTildeInPath
        return PBSMackupKit.realPath(expanded) ?? expanded
    }

    /// Why `folder` cannot be added to the backed-up `sources`, as a sentence for the owner;
    /// nil when it can. A run reads from a snapshot of the Mac's own disk, so a folder on
    /// another disk is not there to read. And it hands the client one archive per folder,
    /// which stops when two of them have the same name; names that differ only in capitals
    /// count as the same, because the files kept per archive on this Mac would be the same.
    public static func objection(toAdding folder: String, to sources: [String]) -> String? {
        let path = realPath(folder), name = (folder as NSString).lastPathComponent
        var info = stat(), disk = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return "“\(name)” is not a folder." }
        if stat("/System/Volumes/Data", &disk) == 0, info.st_dev != disk.st_dev {
            return "“\(name)” is on another disk. Only folders on this Mac's own disk can be backed up."
        }
        for source in sources {
            if realPath(source) == path { return "“\(name)” is already in the list." }
            if archiveName(for: realPath(source)).lowercased() == archiveName(for: path).lowercased() {
                return "“\(name)” would get the same name in the backup as \(source). To back up both, rename one of the two folders."
            }
        }
        return nil
    }
}
