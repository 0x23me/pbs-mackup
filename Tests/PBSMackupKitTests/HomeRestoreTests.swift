import Darwin
import Foundation
import Testing
@testable import PBSMackupKit

private func snapshot(_ name: String, _ archives: [String], at seconds: TimeInterval) -> Client.Snapshot {
    Client.Snapshot(name: name, time: Date(timeIntervalSince1970: seconds), archives: archives, size: nil)
}

private let listed = [
    snapshot("host/old-mac/2026-11-10T08:00:00Z", ["me.pxar"], at: 1),
    snapshot("host/old-mac/2026-11-12T08:00:00Z", ["me.pxar", "Projects.pxar"], at: 3),
    snapshot("host/office/2026-11-11T08:00:00Z", ["Projects.pxar"], at: 2),
]

@Test func homeRestoreTakesTheNewestSnapshotOfTheOneMacThatHasTheFolder() throws {
    let chosen = try HomeRestore.choose(from: listed, archive: "me.pxar", requested: nil, group: nil)
    #expect(chosen.name == "host/old-mac/2026-11-12T08:00:00Z")
}

@Test func homeRestoreDoesNotGuessBetweenTwoMacs() throws {
    #expect(throws: Failure.self) { try HomeRestore.choose(from: listed, archive: "Projects.pxar", requested: nil, group: nil) }
    let chosen = try HomeRestore.choose(from: listed, archive: "Projects.pxar", requested: nil, group: "office")
    #expect(chosen.name == "host/office/2026-11-11T08:00:00Z")
}

@Test func homeRestoreTakesTheSnapshotItIsGivenOnlyWithTheFolder() throws {
    let older = "host/old-mac/2026-11-10T08:00:00Z"
    #expect(try HomeRestore.choose(from: listed, archive: "me.pxar", requested: older, group: nil).name == older)
    #expect(throws: Failure.self) { try HomeRestore.choose(from: listed, archive: "Projects.pxar", requested: older, group: nil) }
    #expect(throws: Failure.self) { try HomeRestore.choose(from: listed, archive: "me.pxar", requested: "host/x/2026-01-01T00:00:00Z", group: nil) }
    #expect(throws: Failure.self) { try HomeRestore.choose(from: listed, archive: "you.pxar", requested: nil, group: nil) }
}

@Test func homeRestoreFindsTheOldOwnerInACLsAndPutsTheNewOneThere() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("home-restore-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Public/Drop Box"), withIntermediateDirectories: true)
    defer { removeRestored(root) }
    let dropBox = root.appendingPathComponent("Public/Drop Box").path
    let locked = root.appendingPathComponent("locked.txt").path
    FileManager.default.createFile(atPath: locked, contents: Data("x".utf8))

    // An owner as another Mac knew them, next to the group everyone that every Mac knows.
    let stranger = UUID()
    for path in [dropBox, locked] {
        #expect(tool("/bin/chmod", ["+a", "everyone deny delete", path]).status == 0)
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { Issue.record("no ACL on \(path)"); return }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var acls: acl_t? = acl, entry: acl_entry_t?
        #expect(acl_create_entry(&acls, &entry) == 0)
        acl_set_tag_type(entry, ACL_EXTENDED_ALLOW)
        var guid = guid_t(g_guid: stranger.uuid)
        #expect(acl_set_qualifier(entry, &guid) == 0)
        var permissions: acl_permset_t?
        acl_get_permset(entry, &permissions)
        acl_add_perm(permissions, ACL_READ_DATA)
        acl_set_permset(entry, permissions)
        #expect(acl_set_link_np(path, ACL_TYPE_EXTENDED, acls) == 0)
    }
    chflags(locked, UInt32(UF_IMMUTABLE))

    #expect(HomeRestore.strangers(in: root) == [stranger])
    let me = try #require(HomeRestore.generatedUID(of: getuid()))
    let replaced = HomeRestore.replaceInACLs(root, stranger, with: me)
    #expect(replaced.changed == 2)
    #expect(replaced.failed.isEmpty)
    #expect(HomeRestore.strangers(in: root).isEmpty)
    var info = stat()
    lstat(locked, &info)
    #expect(info.st_flags & UInt32(UF_IMMUTABLE) != 0, "the lock is back on")
    let text = tool("/bin/ls", ["-led", dropBox]).output
    #expect(text.contains("everyone deny delete"))
    #expect(text.contains(NSUserName()))
}

@Test func homeRestoreSeesProgramsOfAUser() {
    #expect(HomeRestore.hasPrograms(uid: getuid()))
    #expect(!HomeRestore.hasPrograms(uid: 4242))
}

@Test func restoreProgressIsTheLastPercentTheClientWrote() {
    let output = Data("Using encryption key from file descriptor..\nprogress 22% (200 MiB of 901 MiB in 5s, 39 MiB/s)\nprogress 57% (514 MiB".utf8)
    #expect(RestoreService.progress(in: output) == 0.57)
    #expect(RestoreService.progress(in: Data("restore complete".utf8)) == nil)
}

@Test func homeRestoreLeavesTheCloudOutAndKeepsTheRest() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("home-restore-\(UUID().uuidString)")
    defer { removeRestored(root) }
    for folder in HomeRestore.cloudFolders + ["Library/Application Support/Notes", "Documents"] {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
    }
    let account = HomeRestore.Account(name: NSUserName(), uid: getuid(), home: root)
    let notes = HomeRestore.adapt(root, to: account)
    for folder in HomeRestore.cloudFolders {
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(folder).path), "\(folder) is left out")
    }
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Library/Application Support/Notes").path))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Documents").path))
    #expect(notes.contains { $0.contains("iCloud") })
}

@Test func homeRestoreSeesWhoIsLoggedIn() {
    #expect(!HomeRestore.isLoggedIn("nobody-\(UUID().uuidString.prefix(8))"))
}
