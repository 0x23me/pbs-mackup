import Foundation

extension Paths {
    /// There while automatic backups are paused. In the support folder, not the cache, so that
    /// nothing but the app clears it away.
    public static var paused: URL { support.appendingPathComponent("paused") }
}

/// Whether automatic backups are paused: scheduled runs do nothing then, a run started by hand
/// still runs. It is a file of its own that the app makes and removes and the run tool only
/// looks for, so the state file has one writer, the run tool.
public enum Pause {
    public static var isOn: Bool { FileManager.default.fileExists(atPath: Paths.paused.path) }

    public static func set(_ on: Bool) throws {
        if on {
            try FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
            try Data().write(to: Paths.paused)
        } else if isOn {
            try FileManager.default.removeItem(at: Paths.paused)
        }
    }
}
