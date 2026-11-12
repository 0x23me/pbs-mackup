import Foundation

public struct Config: Codable, Equatable {
    /// What to do when the APFS snapshot cannot be mounted, which is the case without Full Disk Access.
    public enum FrozenSnapshot: String, Codable {
        /// The run fails. This is what the mac-backup-runs spec asks for.
        case required
        /// Prototype setting: back up the live folders instead and say so in the run record.
        case whenPermitted
    }

    /// As the client takes it: `user@realm!token@host[:port]:datastore`.
    public var repository: String
    public var namespace: String
    /// The backup group is `host/<backupID>`.
    public var backupID: String
    /// Absolute folders on the Data volume. Each becomes one archive named after the folder.
    public var sources: [String]
    /// The owner's own exclusions, patterns as in `.pxarexclude`. `defaultExcludes` always apply too.
    public var excludes: [String]
    public var frozenSnapshot: FrozenSnapshot
    /// Only set to use a client other than the one in the app bundle.
    public var clientPath: String?
    /// How many files to restore and compare after each backup; 20 when absent, 0 for none.
    public var sampleFiles: Int?
    /// The server's certificate fingerprint, confirmed at setup. Only set for a certificate that
    /// is not publicly trusted: a public one changes at every renewal.
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

    public func save(to url: URL = Paths.config) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
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

    /// Archive name for a source folder: its last path component, limited to what PBS accepts.
    public static func archiveName(for source: String) -> String {
        let name = URL(fileURLWithPath: source).lastPathComponent
        let allowed = name.map { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) ? $0 : "_" }
        return String(allowed) + ".pxar"
    }
}
