import CoreServices
import Foundation

/// macOS keeps a log of what changed on a volume (FSEvents), and it can be asked what changed
/// since a position in that log. A run remembers the position before it takes its snapshot;
/// the next run asks for the changes since then and reads only those folders.
///
/// The log is only trusted where it says it is complete: any sign of a gap makes the answer
/// `unusable`, and the run reads everything.
public enum ChangeLog {
    public struct Position: Codable, Equatable, Sendable {
        public var event: UInt64
        /// Identifies the log. macOS gives a volume a new one when it had to start its log over.
        public var log: String
    }

    /// Where the log of the volume that holds `path` is now.
    public static func position(of path: String) -> Position? {
        var info = stat()
        guard stat(path, &info) == 0, let uuid = FSEventsCopyUUIDForDevice(info.st_dev),
              let text = CFUUIDCreateString(nil, uuid) else { return nil }
        return Position(event: FSEventsGetCurrentEventId(), log: text as String)
    }

    public struct Changes: Equatable, Sendable {
        /// Folders in which entries changed: they are read again, their subfolders are not.
        public var folders: Set<String> = []
        /// Folders that are read again with everything below them: new, renamed and replaced
        /// folders, and those macOS itself asks to rescan.
        public var subtrees: Set<String> = []

        /// As the client takes it with `--changed-dirs`: records of `d` or `r` and a path, each
        /// ended by a zero byte. `prefix` goes before every path (the snapshot's mount point).
        public func records(prefix: String = "") -> Data {
            var data = Data()
            for (kind, paths) in [("r", subtrees), ("d", folders.subtracting(subtrees))] {
                for path in paths.sorted() {
                    data.append(contentsOf: Array((kind + prefix + path).utf8) + [0])
                }
            }
            return data
        }
    }

    public enum Answer: Equatable, Sendable {
        case changes(Changes)
        /// Why the log cannot say what changed.
        case unusable(String)
    }

    /// What changed at or below `roots` since `since`. `marker` is a folder on the same volume
    /// that nothing else writes to: a file is made there and the answer is complete once the
    /// log reports it, because the log reports in the order things happened.
    public static func changes(below roots: [String], since: Position, marker: URL, timeout: TimeInterval = 120) -> Answer {
        guard let first = roots.first, let now = position(of: first) else { return .unusable("this volume keeps no change log") }
        guard now.log == since.log else { return .unusable("macOS started its change log over") }
        guard since.event <= now.event else { return .unusable("the remembered position is ahead of the change log") }
        do { try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true) } catch {
            return .unusable("no marker folder: \(error.localizedDescription)")
        }
        guard let markerPath = realpath(marker.path, nil).map({ pointer -> String in defer { free(pointer) }; return String(cString: pointer) }) else {
            return .unusable("no marker folder")
        }

        let collector = Collector(roots: roots, marker: markerPath)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(collector).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            let collector = Unmanaged<Collector>.fromOpaque(info!).takeUnretainedValue()
            guard let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] else { return }
            for index in 0..<count { collector.take(paths[index], Int(flags[index])) }
        }
        let flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
        guard let stream = FSEventStreamCreate(nil, callback, &context, (roots + [markerPath]) as CFArray, since.event, 0,
                                               FSEventStreamCreateFlags(flags)) else {
            return .unusable("the change log cannot be read")
        }
        let queue = DispatchQueue(label: "pbs-mackup.changes")
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
            return .unusable("the change log cannot be read")
        }
        defer { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }

        let deadline = Date().addingTimeInterval(timeout)
        func wait(until done: () -> Bool) -> Bool {
            while !queue.sync(execute: done) {
                if Date() > deadline { return false }
                usleep(20_000)
            }
            return true
        }
        guard wait(until: { collector.historyDone || collector.failure != nil }) else { return .unusable("the change log did not answer in time") }
        // What happened a moment ago may not be reported yet. A change of our own, made now,
        // marks the end: everything before it has been reported once it is.
        let file = marker.appendingPathComponent(UUID().uuidString)
        queue.sync { collector.waitingFor = markerPath + "/" + file.lastPathComponent }
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { return .unusable("no marker file") }
        defer { try? FileManager.default.removeItem(at: file) }
        FSEventStreamFlushAsync(stream)
        guard wait(until: { collector.markerSeen || collector.failure != nil }) else { return .unusable("the change log did not answer in time") }
        return queue.sync { collector.failure.map { .unusable($0) } ?? .changes(collector.changes) }
    }

    private final class Collector {
        let roots: [String]
        let marker: String
        var changes = Changes()
        var historyDone = false
        var waitingFor: String?
        var markerSeen = false
        var failure: String?

        init(roots: [String], marker: String) {
            self.roots = roots
            self.marker = marker
        }

        func take(_ reported: String, _ flags: Int) {
            if flags & kFSEventStreamEventFlagHistoryDone != 0 { historyDone = true; return }
            let path = reported.count > 1 && reported.hasSuffix("/") ? String(reported.dropLast()) : reported
            if path == marker || path.hasPrefix(marker + "/") {
                if path == waitingFor { markerSeen = true }
                return
            }
            if flags & (kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0 {
                failure = "the change log lost events"; return
            }
            if flags & kFSEventStreamEventFlagEventIdsWrapped != 0 { failure = "the change log started its numbering over"; return }
            if flags & kFSEventStreamEventFlagRootChanged != 0 { failure = "a backed-up folder was moved"; return }
            if flags & (kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount) != 0 { return }
            let inside = roots.contains { path == $0 || path.hasPrefix($0 + "/") }
            if flags & kFSEventStreamEventFlagMustScanSubDirs != 0 {
                // For a backed-up folder itself or something above it, that is everything.
                guard inside else { failure = "the change log has a gap"; return }
                if roots.contains(path) { failure = "the change log has a gap"; return }
                changes.subtrees.insert(path)
                return
            }
            guard inside else { return }
            let parent = roots.contains(path) ? path : (path as NSString).deletingLastPathComponent
            let isFolder = flags & kFSEventStreamEventFlagItemIsDir != 0
            let isOther = flags & (kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsSymlink
                                   | kFSEventStreamEventFlagItemIsHardlink | kFSEventStreamEventFlagItemIsLastHardlink) != 0
            changes.folders.insert(parent)
            if isFolder {
                // A folder that appeared under this name, by being made, moved here or put in
                // place of another, may hold anything: nothing below it was reported.
                let appeared = kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemRemoved
                if flags & appeared != 0 { changes.subtrees.insert(path) }
            } else if !isOther {
                // No word on what it is: taken as a folder whose entries changed.
                changes.folders.insert(path)
            }
        }
    }
}
