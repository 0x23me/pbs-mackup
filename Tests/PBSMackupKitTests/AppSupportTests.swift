import Foundation
import Testing
@testable import PBSMackupKit

// What the app leans on outside its windows: being told when its support folder changes, and
// clearing away the files it opened from a backup.

/// What a watcher's callback found in the folder each time it was called.
private final class Sightings: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []

    func add(_ sighting: String) { lock.withLock { seen.append(sighting) } }
    var count: Int { lock.withLock { seen.count } }

    /// Waits until the callback has been called again after the first `count` times and found `expected`.
    func arrives(_ expected: String, after count: Int) async throws -> Bool {
        for _ in 0..<100 {
            if lock.withLock({ seen.dropFirst(count).contains(expected) }) { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}

@Test func aWatchedFolderTellsWhenAFileInItIsMadeReplacedOrRemoved() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("pbs-mackup-watch-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    // Two folders down from one that is there: the watcher starts before its folder exists, as
    // the app does before anything was set up.
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let folder = home.appendingPathComponent("Application Support/pbs-mackup")
    let state = folder.appendingPathComponent("state.json"), paused = folder.appendingPathComponent("paused")

    /// The visible names in the folder and what the state file says, or that there is no folder.
    func look() -> String {
        guard let names = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        else { return "no folder" }
        let text = (try? String(contentsOf: state, encoding: .utf8)) ?? ""
        return names.map(\.lastPathComponent).sorted().joined(separator: ",") + ": " + text
    }
    let sightings = Sightings()
    let watcher = FolderWatcher(folder, queue: DispatchQueue(label: "watcher")) { sightings.add(look()) }
    defer { withExtendedLifetime(watcher) {} }            // it watches for as long as it is kept

    /// Does `change` and says whether the watcher called back afterwards and saw `expected`.
    func after(_ change: () throws -> Void, sees expected: String) async throws -> Bool {
        let before = sightings.count
        try change()
        return try await sightings.arrives(expected, after: before)
    }

    #expect(try await after({ try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }, sees: ": "))
    // Made and removed like the pause file, written and replaced like the state file.
    #expect(try await after({ try Data().write(to: paused) }, sees: "paused: "))
    #expect(try await after({ try Data("one".utf8).write(to: state, options: .atomic) }, sees: "paused,state.json: one"))
    #expect(try await after({ try Data("two".utf8).write(to: state, options: .atomic) }, sees: "paused,state.json: two"))
    #expect(try await after({ try FileManager.default.removeItem(at: paused) }, sees: "state.json: two"))

    // The folder goes away and comes back: the watcher is told both, and watches the new one.
    #expect(try await after({ try FileManager.default.removeItem(at: folder) }, sees: "no folder"))
    #expect(try await after({ try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }, sees: ": "))
    #expect(try await after({ try Data("three".utf8).write(to: state, options: .atomic) }, sees: "state.json: three"))

    // Nothing changes, nothing is said.
    let quiet = sightings.count
    try await Task.sleep(for: .milliseconds(500))
    #expect(sightings.count == quiet)
}

extension PrivateHomeTests {
@Test func theFilesOpenedFromABackupAreClearedAwayWhateverTheirPermissions() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("pbs-mackup-preview-\(UUID().uuidString)")
    setenv("PBS_MACKUP_HOME", home.path, 1)
    defer { unsetenv("PBS_MACKUP_HOME"); try? FileManager.default.removeItem(at: home) }
    Paths.emptyPreview()                                  // nothing there yet: nothing to do
    #expect(!FileManager.default.fileExists(atPath: Paths.cache.path))

    // As restored for a look: a folder of its own with the file in it. Here both carry an ACL
    // that forbids deleting them, and the file is locked as well, which a restored item can be.
    let opened = Paths.preview.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: opened, withIntermediateDirectories: true)
    let file = opened.appendingPathComponent("letter.txt")
    try Data("from the backup".utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
    #expect(tool("/bin/chmod", ["+a", "everyone deny delete", file.path]).status == 0)
    #expect(tool("/bin/chmod", ["+a", "everyone deny delete,delete_child", opened.path]).status == 0)
    #expect(tool("/usr/bin/chflags", ["uchg", file.path]).status == 0)
    #expect(throws: (any Error).self) { try FileManager.default.removeItem(at: Paths.preview) }
    #expect(FileManager.default.fileExists(atPath: file.path))

    Paths.emptyPreview()
    #expect(!FileManager.default.fileExists(atPath: Paths.preview.path))
    #expect(FileManager.default.fileExists(atPath: Paths.cache.path))          // only the preview folder goes
}
}
