import Foundation

// The state file (`state.json`) is how the run tool tells the app what happened and what is
// happening. The run tool rewrites it atomically; the app only reads it, except for `paused`.

public enum Trigger: String, Codable { case scheduled, manual }

public enum Outcome: String, Codable { case success, skipped, cancelled, failed }

public struct RunRecord: Codable, Equatable {
    public var start: Date
    public var end: Date
    public var trigger: Trigger
    public var outcome: Outcome
    /// Why it was skipped or failed, in words for the menu.
    public var reason: String?
    /// The step that failed: snapshot, mount, backup, ...
    public var step: String?
    /// The PBS snapshot, e.g. `host/my-mac/2026-11-12T08:00:00Z`.
    public var snapshot: String?
    /// False when the live folders were read because the APFS snapshot could not be mounted.
    public var frozen: Bool
    public var result: BackupResult
    /// Files restored from the new snapshot and compared after the upload.
    public var checkedFiles: Int?
    /// Of those, the ones that differed, each with what differed.
    public var mismatches: [String]?
    /// How the run found what to read: from the change log, or why it read everything.
    public var changes: String?
    public var log: String?

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// What the client reported about one backup. Amounts are kept as the client prints them.
public struct BackupResult: Codable, Equatable {
    public var totalFiles: Int?
    public var unchangedFiles: Int?
    public var changedFiles: Int?
    public var archives: [Archive] = []
    public var clientDuration: String?
    public var error: String?
    /// From the client's result record.
    public var entries: Int?
    public var bytesProcessed: Int64?
    public var bytesReused: Int64?
    public var bytesUploaded: Int64?
    /// Files whose contents are not on disk (iCloud placeholders); at most 1000 are named.
    public var skippedPlaceholders: [String]?
    public var skippedPlaceholderCount: Int?
    /// Entries left out because they are excluded from Time Machine.
    public var timeMachineExcluded: Int?
    public var warnings: [String]?
    /// Folders taken over from the previous backup without being read, and folders read.
    public var carriedFolders: Int?
    public var readFolders: Int?
    /// "used", or "ignored: <reason>" when the client read everything despite a list of changes.
    public var changeList: String?

    public struct Archive: Codable, Equatable {
        public var name: String
        public var total: String
        public var uploaded: String
        public var reused: String?
    }
    public init() {}
}

public struct Progress: Codable, Equatable {
    /// preparing, backing up, checking, cleaning up
    public var step: String
    /// Amounts and time as text for the menu.
    public var processed: String?
    public var uploaded: String?
    public var elapsed: String?
    public var entries: Int?
    public var bytesProcessed: Int64?
    public var bytesUploaded: Int64?
    /// The upload speed over the last seconds, as text ("0.85 Gbit/s") and in bits per second;
    /// absent while next to nothing is being sent.
    public var speed: String?
    public var bitsPerSecond: Double?
    /// What the last successful run processed in total; the bar's full length. Nil on a first run.
    public var expectedBytes: Int64?
    /// The entry being read, relative to its folder.
    public var path: String?
    public var updated: Date
}

public struct Running: Codable, Equatable {
    public var pid: Int32
    /// The client the run started, so a later run can stop it if the run tool died.
    public var clientPID: Int32?
    public var start: Date
    public var trigger: Trigger
    public var progress: Progress
}

/// What the next run needs to read only what changed: where the change log was before the
/// last successful run took its snapshot, and which backup that run made.
public struct ChangeBase: Codable, Equatable {
    public var position: ChangeLog.Position
    public var snapshot: String
    /// A digest of what decided the content of that backup (folders, exclusions, client).
    /// When it differs, the next run reads everything.
    public var settings: String
}

public struct State: Codable, Equatable {
    public var version = 1
    public var running: Running?
    /// Date of the APFS snapshot the current run created, written before it is mounted, so the
    /// next run can remove it after a crash.
    public var localSnapshot: String?
    public var last: RunRecord?
    public var lastSuccess: RunRecord?
    public var consecutiveFailures = 0
    public var changeBase: ChangeBase?
    public var history: [RunRecord] = []
    /// Set by the app: scheduled runs do nothing while true.
    public var paused = false

    public init() {}

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func load(from url: URL = Paths.state) -> State {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), let state = try? decoder.decode(State.self, from: data) else {
            return State()
        }
        return state
    }

    public func save(to url: URL = Paths.state) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try State.encoder.encode(self).write(to: url, options: .atomic)
    }

    public mutating func finish(_ record: RunRecord) {
        running = nil
        last = record
        switch record.outcome {
        case .success: lastSuccess = record; consecutiveFailures = 0
        case .failed: consecutiveFailures += 1
        case .skipped, .cancelled: break
        }
        history = Array((history + [record]).suffix(100))
    }
}
