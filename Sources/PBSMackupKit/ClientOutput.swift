import Foundation

/// Reads what the client prints during a backup: JSON records (`--progress-json`, described in
/// the fork's `pbs-client/src/report.rs`) and the lines of its log, which carry the per-archive
/// amounts and the error text.
public struct ClientOutput {
    public struct ProgressRecord: Equatable {
        public let entries: Int
        public let bytesProcessed: Int64
        public let bytesUploaded: Int64
        /// What went over the network so far; nil from a client that does not count it.
        public var bytesSent: Int64? = nil
        public let path: String
        public let elapsed: Double
    }

    private struct Record: Decodable {
        let type: String
        let entries: Int?
        let bytes_processed: Int64?
        let bytes_reused: Int64?
        let bytes_uploaded: Int64?
        let bytes_sent: Int64?
        let path: String?
        let elapsed: Double?
        let snapshot: String?
        let skipped_placeholders: [String]?
        let skipped_placeholder_count: Int?
        let time_machine_excluded: Int?
        let warnings: [String]?
        let carried_dirs: Int?
        let walked_dirs: Int?
        let change_list: String?
    }

    public private(set) var snapshot: String?
    public private(set) var progress: ProgressRecord?
    public private(set) var result = BackupResult()

    public init() {}

    /// Returns true when the line changed the progress.
    @discardableResult
    public mutating func read(_ line: String) -> Bool {
        let line = line.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("{") {
            guard let record = try? JSONDecoder().decode(Record.self, from: Data(line.utf8)) else { return false }
            if record.type == "progress" {
                progress = ProgressRecord(entries: record.entries ?? 0, bytesProcessed: record.bytes_processed ?? 0,
                                          bytesUploaded: record.bytes_uploaded ?? 0, bytesSent: record.bytes_sent,
                                          path: record.path ?? "", elapsed: record.elapsed ?? 0)
                return true
            }
            if let name = record.snapshot { snapshot = name }
            result.entries = record.entries
            result.bytesProcessed = record.bytes_processed
            result.bytesReused = record.bytes_reused
            result.bytesUploaded = record.bytes_uploaded
            result.skippedPlaceholders = record.skipped_placeholders
            result.skippedPlaceholderCount = record.skipped_placeholder_count
            result.timeMachineExcluded = record.time_machine_excluded
            result.warnings = record.warnings
            result.carriedFolders = record.carried_dirs
            result.readFolders = record.walked_dirs
            result.changeList = record.change_list
        } else if let rest = line.dropping(prefix: "Starting backup: ") {
            // "[namespace]:host/id/time" or "host/id/time"
            snapshot = rest.range(of: "]:").map { String(rest[$0.upperBound...]) } ?? rest
        } else if let rest = line.dropping(prefix: "- ") {
            let count = Int(rest.prefix(while: \.isNumber))
            if rest.contains(" total files") { result.totalFiles = count }
            else if rest.contains(" unchanged, reusable files") { result.unchangedFiles = count }
            else if rest.contains(" changed or non-reusable files") { result.changedFiles = count }
        } else if let rest = line.dropping(prefix: "Duration: ") {
            result.clientDuration = rest
        } else if let rest = line.dropping(prefix: "Error: ") {
            result.error = rest
        } else if let colon = line.range(of: ": had to backup "), let of = line.range(of: " of ", range: colon.upperBound..<line.endIndex),
                  let paren = line.range(of: " (compressed", range: of.upperBound..<line.endIndex) {
            let name = String(line[..<colon.lowerBound])
            let archive = BackupResult.Archive(name: name, total: String(line[of.upperBound..<paren.lowerBound]),
                                               uploaded: String(line[colon.upperBound..<of.lowerBound]), reused: nil)
            result.archives.removeAll { $0.name == name }
            result.archives.append(archive)
        } else if let colon = line.range(of: ": backup was done incrementally, reused "),
                  let index = result.archives.firstIndex(where: { $0.name == String(line[..<colon.lowerBound]) }) {
            result.archives[index].reused = String(line[colon.upperBound...])
        }
        return false
    }
}

extension String {
    func dropping(prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
