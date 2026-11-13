import Foundation

/// The frozen view a run reads from: a local APFS snapshot of the Data volume, taken with
/// `tmutil`, mounted read-only, and deleted again by its date. Only snapshots created here are
/// ever deleted; Time Machine's own are never touched.
public enum LocalSnapshot {
    public struct Failure: Error, CustomStringConvertible {
        public let step: String
        public let message: String
        public var description: String { "\(step): \(message)" }
    }

    /// Takes a snapshot and returns its date, the handle for mounting and deleting it.
    public static func create() throws -> String {
        let result = tool("/usr/bin/tmutil", ["localsnapshot"])
        guard result.status == 0, let range = result.output.range(of: "date: ") else {
            throw Failure(step: "snapshot", message: result.output)
        }
        return String(result.output[range.upperBound...].prefix(while: { $0.isNumber || $0 == "-" }))
    }

    /// Mounting needs Full Disk Access; without it `mount_apfs` reports "Operation not permitted".
    public static func mount(_ date: String, at mountPoint: URL) throws {
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let result = tool("/sbin/mount_apfs", ["-o", "ro,nobrowse", "-s", "com.apple.TimeMachine.\(date).local",
                                              "/System/Volumes/Data", mountPoint.path])
        guard result.status == 0 else { throw Failure(step: "mount", message: result.output) }
    }

    public static func isMounted(_ mountPoint: URL) -> Bool {
        var info = statfs()
        guard statfs(mountPoint.path, &info) == 0 else { return false }
        let on = withUnsafePointer(to: &info.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return on == realPath(mountPoint.path)
    }

    public static func unmount(_ mountPoint: URL) {
        guard isMounted(mountPoint) else { return }
        if tool("/sbin/umount", [mountPoint.path]).status != 0 {
            tool("/usr/sbin/diskutil", ["unmount", "force", mountPoint.path])
        }
    }

    public static func delete(_ date: String) {
        tool("/usr/bin/tmutil", ["deletelocalsnapshots", date])
    }
}
