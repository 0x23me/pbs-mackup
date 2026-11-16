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
    ///
    /// The log has no word of a file that a program writes to and keeps open: macOS logs a
    /// change to a file's contents when the program that wrote it closes it, or ends, and not
    /// before; writes through a mapping of the file are not logged either. So the folders of
    /// the files open for writing now (`writing`) are read as well. A run asks after it took
    /// its snapshot: a file written before the snapshot is then either still open, or closed
    /// and in the log before the marker.
    public static func changes(below roots: [String], since: Position, marker: URL, timeout: TimeInterval = 120,
                               writing: () -> Set<String> = filesOpenForWriting) -> Answer {
        guard let first = roots.first, let now = position(of: first) else { return .unusable("this volume keeps no change log") }
        guard now.log == since.log else { return .unusable("macOS started its change log over") }
        guard since.event <= now.event else { return .unusable("the remembered position is ahead of the change log") }
        do { try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true) } catch {
            return .unusable("no marker folder: \(error.localizedDescription)")
        }
        guard let markerPath = realPath(marker.path) else { return .unusable("no marker folder") }

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
        defer {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream)
            // The stream only borrows the collector, and Swift may let go of it after its last
            // use below. It is held until the stream has stopped and a report that was on its
            // way has been taken.
            queue.sync {}
            withExtendedLifetime(collector) {}
            FSEventStreamRelease(stream)
        }

        let deadline = Date().addingTimeInterval(timeout)
        func wait(until done: () -> Bool) -> Bool {
            while !queue.sync(execute: done) {
                if Date() > deadline { return false }
                usleep(20_000)
            }
            return true
        }
        guard wait(until: { collector.historyDone || collector.failure != nil }) else { return .unusable("the change log did not answer in time") }
        let open = writing()
        queue.sync { for path in open { collector.takeOpen(path) } }
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

        /// A file open for writing: its folder is read.
        func takeOpen(_ reported: String) {
            // The Data volume's own name for a path in the home folder.
            let data = "/System/Volumes/Data"
            let path = reported.hasPrefix(data + "/") ? String(reported.dropFirst(data.count)) : reported
            guard !roots.contains(path), roots.contains(where: { path.hasPrefix($0 + "/") }) else { return }
            changes.folders.insert((path as NSString).deletingLastPathComponent)
        }
    }

    /// The files that the user's programs have open for writing now, or mapped so that they
    /// can write to them, as the paths macOS gives for them. The programs of other users and
    /// of the system cannot be asked: what they write is in the log once they close it.
    public static func filesOpenForWriting() -> Set<String> {
        var found = Set<String>()
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return found }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let listed = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        for pid in pids.prefix(Int(max(listed, 0))) where pid > 0 {
            // Descriptors opened for writing.
            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 16)
            let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))
            guard got > 0 else { continue }
            for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_VNODE {
                var info = vnode_fdinfowithpath()
                let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size,
                      info.pfi.fi_openflags & UInt32(FWRITE) != 0 else { continue }
                let path = cString(info.pvip.vip_path)
                if !path.isEmpty { found.insert(path) }
            }
            // Files mapped into memory where writing is allowed, which stay so after their
            // descriptor is closed. Private mappings are counted too: telling them apart is not
            // worth the risk, and reading a folder too many costs little.
            var address: UInt64 = 0
            while true {
                var region = proc_regionwithpathinfo()
                let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
                guard proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, address, &region, size) == size else { break }
                let range = region.prp_prinfo
                if range.pri_max_protection & UInt32(VM_PROT_WRITE) != 0 {
                    let path = cString(region.prp_vip.vip_path)
                    if !path.isEmpty { found.insert(path) }
                }
                guard range.pri_size > 0 else { break }
                address = range.pri_address + range.pri_size
            }
        }
        return found
    }

    private static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
