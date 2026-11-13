import Darwin
import Foundation

// The state file (`state.json`) is how the run tool tells the app what happened and what is
// happening. The run tool rewrites it atomically and is the only one to write it; the app
// only reads it.

public enum Trigger: String, Codable { case scheduled, manual }

public enum Outcome: String, Codable { case success, skipped, cancelled, failed }

/// The step a run failed at.
public enum Step: String, Codable { case setup, snapshot, backup, verify }

/// What a run is doing.
public enum Phase: String, Codable {
    case preparing, backingUp = "backing up", checking, cleaningUp = "cleaning up"
}

public struct RunRecord: Codable, Equatable {
    public var start: Date
    public var end: Date
    public var trigger: Trigger
    public var outcome: Outcome
    /// Why it was skipped or failed, in words for the menu.
    public var reason: String?
    public var step: Step?
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
    public var step: Phase
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

    /// Whether the run tool that wrote this is still at it. After a crash or a restart the
    /// record stays in the file for up to five minutes, and its process id may be another
    /// program's by then.
    public var isLive: Bool { Running.isProcess(pid, program: "pbs-mackup-run", startedBy: start) }

    /// True when `pid` is a process that runs `program` and began no later than `date`. One
    /// that began after it has taken the id over from the process that was meant.
    static func isProcess(_ pid: Int32, program: String, startedBy date: Date) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4096)   // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
              String(cString: buffer).hasSuffix("/" + program) else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        // In whole seconds, which is how the state file keeps the start of a run.
        return Double(info.pbi_start_tvsec) <= date.timeIntervalSince1970
    }
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
    /// Not in use any more: the pause is a file of its own, see `Pause`. A `true` from before
    /// that is moved there by the next run. The field is still written, as `false`, for an
    /// app from before that is still running and cannot read the file without it.
    var paused = false

    public init() {}

    public static func load(from url: URL = Paths.state) -> State {
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder.iso8601.decode(State.self, from: data) else {
            return State()
        }
        return state
    }

    public func save(to url: URL = Paths.state) throws {
        let encoder = JSONEncoder.iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
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

    /// When the next scheduled run is due; the run tool and the app's "Next backup" both go by
    /// this. It is one interval after the last successful run began. A skipped run changes
    /// nothing, so it is tried again when launchd next starts the tool, five minutes later. A
    /// failed run is tried again a quarter of an hour after it ended, then after twice as long
    /// each time it fails again, never after more than the interval. A cancelled run is
    /// followed by a whole interval, so that it does not start over right after the owner
    /// stopped it.
    public func nextRun(intervalMinutes: Int) -> Date {
        let interval = Double(intervalMinutes * 60)
        var next = lastSuccess?.start.addingTimeInterval(interval) ?? .distantPast
        guard let last else { return next }
        switch last.outcome {
        case .failed:
            let wait = min(interval, 900 * pow(2, Double(min(max(consecutiveFailures, 1), 16) - 1)))
            next = max(next, last.end.addingTimeInterval(wait))
        case .cancelled:
            next = max(next, last.start.addingTimeInterval(interval))
        case .success, .skipped:
            break
        }
        return next
    }
}
