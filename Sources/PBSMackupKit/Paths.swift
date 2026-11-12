import Foundation

/// Where the run tool and the app keep their files. `PBS_MACKUP_HOME` moves everything under one
/// folder, which the tests use.
public enum Paths {
    static var override: URL? {
        ProcessInfo.processInfo.environment["PBS_MACKUP_HOME"].map { URL(fileURLWithPath: $0) }
    }
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    public static var support: URL {
        override?.appendingPathComponent("support") ?? home.appendingPathComponent("Library/Application Support/pbs-mackup")
    }
    public static var cache: URL {
        override?.appendingPathComponent("cache") ?? home.appendingPathComponent("Library/Caches/pbs-mackup")
    }
    public static var config: URL { support.appendingPathComponent("config.json") }
    public static var state: URL { support.appendingPathComponent("state.json") }
    public static var logs: URL { support.appendingPathComponent("logs") }
    public static var lock: URL { cache.appendingPathComponent("run.lock") }
    public static var mount: URL { cache.appendingPathComponent("mnt") }
    /// Where archives of snapshots are mounted for Finder, one folder each.
    public static var browse: URL { cache.appendingPathComponent("browse") }
    /// The names in the snapshots that were searched, one file each.
    public static var index: URL { cache.appendingPathComponent("index") }
    /// How big the backed-up folders are, one file each, from the last time they were measured.
    public static var sizes: URL { cache.appendingPathComponent("sizes") }
    /// Where a run leaves a file to see how far the change log has come; see `ChangeLog`.
    public static var changeMarker: URL { cache.appendingPathComponent("changes") }
    /// The folders that changed since the last backup, for the client, while a run lasts.
    public static var changedFolders: URL { cache.appendingPathComponent("changed-folders") }
    /// Files opened from a backup to look at; emptied when the app starts.
    public static var preview: URL { cache.appendingPathComponent("preview") }
    /// Touched by the app before it asks launchd to start a run, so the run knows it was started by hand.
    public static var manualRequest: URL { cache.appendingPathComponent("manual-request") }

    public static func createFolders() throws {
        for folder in [support, cache, logs, mount] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }
}

/// The app's bundle identifier, which is also the Keychain service; the launchd job is that
/// plus `.run`. The run tool sits inside the app, so both read it from the bundle and the
/// build script is the one place that names it. Outside a bundle (a development build, the
/// tests) it is the identifier the build script uses when none is given.
public enum Identity {
    public static let bundleID: String = {
        if Bundle.main.bundleURL.pathExtension == "app", let identifier = Bundle.main.bundleIdentifier { return identifier }
        return "me.0x23.pbs-mackup"
    }()
}

public var agentLabel: String { Identity.bundleID + ".run" }
