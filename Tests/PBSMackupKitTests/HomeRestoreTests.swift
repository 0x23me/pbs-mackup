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

// MARK: - Root's work in a folder that is someone else's

/// A folder of its own for one test, and gone after it.
private func withScratch(_ body: (URL) throws -> Void) rethrows {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("home-restore-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { removeRestored(base) }
    try body(base)
}

private func makeFolder(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
}

@discardableResult
private func makeFile(_ url: URL) throws -> URL {
    try makeFolder(url.deletingLastPathComponent())
    try Data("x".utf8).write(to: url)
    return url
}

private func makeLink(_ url: URL, to target: URL) throws {
    try makeFolder(url.deletingLastPathComponent())
    #expect(symlink(target.path, url.path) == 0)
}

private func lock(_ url: URL) {
    #expect(lchflags(url.path, UInt32(UF_IMMUTABLE)) == 0)
}

private func isLocked(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0 && info.st_flags & UInt32(UF_IMMUTABLE) != 0
}

private func addToACL(_ url: URL, _ entry: String) {
    #expect(tool("/bin/chmod", ["+a", entry, url.path]).status == 0)
}

@Test func homeRestoreReachesTheCloudFoldersThroughNoLink() throws {
    try withScratch { base in
        let account = HomeRestore.Account(name: NSUserName(), uid: getuid(), home: base.appendingPathComponent("home"))
        // Someone else's folder, with the names the restore removes from a home folder.
        let other = base.appendingPathComponent("other")
        let theirs = [try makeFile(other.appendingPathComponent("Mobile Documents/theirs.txt")),
                      try makeFile(other.appendingPathComponent("CloudDocs/theirs.txt")),
                      try makeFile(other.appendingPathComponent("theirs.txt"))]

        // `Library` is a link there: a prepared backup can hold one, and so could the owner
        // put one while root worked in a folder they could reach.
        let first = base.appendingPathComponent("first")
        try makeLink(first.appendingPathComponent("Library"), to: other)
        _ = HomeRestore.adapt(first, to: account)
        // A link further down.
        let second = base.appendingPathComponent("second")
        try makeLink(second.appendingPathComponent("Library/Application Support"), to: other)
        _ = HomeRestore.adapt(second, to: account)
        // The cloud folder itself is one: it goes, and what it points to stays.
        let third = base.appendingPathComponent("third")
        try makeLink(third.appendingPathComponent("Library/CloudStorage"), to: other)
        let notes = HomeRestore.adapt(third, to: account)

        for item in theirs { #expect(exists(item), "\(item.path) is not the restore's to remove") }
        #expect(exists(first.appendingPathComponent("Library")))
        #expect(exists(second.appendingPathComponent("Library/Application Support")))
        #expect(!exists(third.appendingPathComponent("Library/CloudStorage")))
        #expect(notes.contains { $0.contains("iCloud") })
    }
}

@Test func removingARestoredFolderTakesOffWhatHoldsItAndFollowsNoLink() throws {
    try withScratch { base in
        let other = base.appendingPathComponent("other")
        let theirs = try makeFile(other.appendingPathComponent("theirs.txt"))
        lock(theirs)
        defer { chflags(theirs.path, 0) }

        let restored = base.appendingPathComponent("restored")
        let locked = try makeFile(restored.appendingPathComponent("locked.txt"))
        addToACL(try makeFile(restored.appendingPathComponent("denied.txt")), "everyone deny delete")
        // Folders that keep their owner out, by the mode and by an ACL, and one that is locked.
        let closed = restored.appendingPathComponent("closed")
        try makeFile(closed.appendingPathComponent("deep/inside.txt"))
        let forbidden = restored.appendingPathComponent("forbidden")
        try makeFile(forbidden.appendingPathComponent("inside.txt"))
        addToACL(forbidden, "everyone deny list,search,delete_child,delete")
        let lockedFolder = restored.appendingPathComponent("locked")
        try makeFile(lockedFolder.appendingPathComponent("inside.txt"))
        // Links out of the folder, one of them locked itself.
        try makeLink(restored.appendingPathComponent("to-folder"), to: other)
        let lockedLink = restored.appendingPathComponent("to-file")
        try makeLink(lockedLink, to: theirs)
        // A file with all of it: nobody may read it, its ACL forbids deleting it, and it is locked.
        let unreadable = try makeFile(restored.appendingPathComponent("unreadable.txt"))
        addToACL(unreadable, "everyone deny delete")
        // Pipes have no descriptor to work on: a locked one, and one whose ACL forbids deleting it.
        let pipe = restored.appendingPathComponent("pipe"), deniedPipe = restored.appendingPathComponent("denied-pipe")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        #expect(mkfifo(deniedPipe.path, 0o600) == 0)
        addToACL(deniedPipe, "everyone deny delete")

        chmod(unreadable.path, 0)
        chmod(closed.path, 0)
        for item in [locked, lockedFolder, unreadable, pipe, lockedLink] { lock(item) }

        let left = removeRestored(restored)
        #expect(left.isEmpty, "left: \(left.paths)")
        #expect(!exists(restored))
        #expect(exists(theirs))
        #expect(isLocked(theirs), "a lock on what a link points to is not the folder's to take off")
    }
}

@Test func removingARestoredFolderThatIsALinkRemovesTheLink() throws {
    try withScratch { base in
        let theirs = try makeFile(base.appendingPathComponent("other/theirs.txt"))
        let restored = base.appendingPathComponent("restored")
        try makeLink(restored, to: theirs.deletingLastPathComponent())
        #expect(removeRestored(restored).isEmpty)
        #expect(!exists(restored))
        #expect(exists(theirs))
        #expect(removeRestored(restored).isEmpty, "where nothing is, nothing is left")
    }
}

@Test func homeRestoreChangesOwnersByTheItemsThemselves() throws {
    try withScratch { base in
        let other = base.appendingPathComponent("other")
        for name in ["a", "b", "c"] { try makeFile(other.appendingPathComponent(name)) }
        let root = base.appendingPathComponent("home")
        try makeFile(root.appendingPathComponent("file.txt"))
        try makeFile(root.appendingPathComponent("Documents/deep/file.txt"))
        try makeLink(root.appendingPathComponent("to-folder"), to: other)
        try makeLink(root.appendingPathComponent("to-nothing"), to: base.appendingPathComponent("nothing"))
        #expect(mkfifo(root.appendingPathComponent("pipe").path, 0o600) == 0)
        let locked = try makeFile(root.appendingPathComponent("locked.txt"))
        lock(locked)

        // Only root gives files away. To oneself everybody may, and it goes the same way.
        let own = HomeRestore.reown(root, from: getuid(), to: getuid())
        // The folder, its two files, Documents, deep and the file in it, two links, the pipe.
        #expect(own.changed == 9)
        #expect(own.failed.isEmpty)
        #expect(isLocked(locked), "the lock is back on")
        #expect(HomeRestore.reown(root, from: 4242, to: getuid()).changed == 0)

        var seen: [String] = []
        Tree.walk(root) { seen.append($0.path) }
        #expect(seen.first == ".")
        #expect(seen.contains("Documents/deep/file.txt"))
        #expect(seen.contains("to-folder"))
        #expect(!seen.contains { $0.hasPrefix("to-folder/") }, "a link is an item and no way further")
        #expect(seen.count == 9)
    }
}

@Test func treeGivesADescriptorOfTheItemThatWasLookedAtAndOfNoOther() throws {
    try withScratch { base in
        let target = try makeFile(base.appendingPathComponent("target.txt"))
        try makeLink(base.appendingPathComponent("name"), to: target)
        let parent = try #require(Tree.open(base.path))
        defer { close(parent) }
        var info = stat()
        #expect(fstatat(parent, "name", &info, AT_SYMLINK_NOFOLLOW) == 0)

        // The link itself, not the file it points to.
        let fd = try #require(Tree.descriptor(of: "name", in: parent, matching: info))
        var opened = stat()
        fstat(fd, &opened)
        close(fd)
        #expect(opened.st_mode & S_IFMT == S_IFLNK)

        // Another item has the name by the time it is opened: no descriptor.
        #expect(unlink(base.appendingPathComponent("name").path) == 0)
        try makeFile(base.appendingPathComponent("name"))
        #expect(Tree.descriptor(of: "name", in: parent, matching: info) == nil)

        // A folder is opened only as one, and a link to one is none.
        try makeLink(base.appendingPathComponent("Library"), to: base)
        #expect(Tree.open(["Library"], below: parent) == nil)
        #expect(Tree.open(base.appendingPathComponent("Library").path) == nil)
    }
}

@Test func homeRestoreWorksInAFolderNobodyElseCanEnter() throws {
    try withScratch { base in
        let home = base.appendingPathComponent("me")
        try makeFolder(home)
        let places = HomeRestore.Places(home: home)
        #expect(places.staging.lastPathComponent == ".pbs-mackup-restore-me")
        #expect(places.staging.deletingLastPathComponent().path == home.deletingLastPathComponent().path, "so that the swap is a rename")
        #expect(places.restored.path == places.staging.path + "/me")
        #expect(places.aside.path == home.path + ".before-restore")

        try HomeRestore.preflight(places, size: 1)
        #expect(throws: Failure.self, "no room") { try HomeRestore.preflight(places, size: Int64.max / 2) }
        try HomeRestore.makeStaging(places.staging)
        var info = stat()
        #expect(lstat(places.staging.path, &info) == 0)
        #expect(info.st_mode & 0o7777 == 0o700)
        // One that an earlier try left is taken as long as it is still closed.
        try HomeRestore.makeStaging(places.staging)
        try HomeRestore.preflight(places, size: nil)

        chmod(places.staging.path, 0o750)
        #expect(throws: Failure.self) { try HomeRestore.makeStaging(places.staging) }
        #expect(throws: Failure.self) { try HomeRestore.preflight(places, size: nil) }
        chmod(places.staging.path, 0o700)
        addToACL(places.staging, "everyone allow list,search")
        #expect(throws: Failure.self) { try HomeRestore.checkStaging(places.staging) }
        // What is in a folder that is not closed is not the restore's, and it removes none of it.
        HomeRestore.discard(places)
        #expect(exists(places.staging))
        #expect(tool("/bin/chmod", ["-N", places.staging.path]).status == 0)
        try HomeRestore.checkStaging(places.staging)

        // A link where the folder should be.
        #expect(rmdir(places.staging.path) == 0)
        let elsewhere = base.appendingPathComponent("elsewhere")
        try makeFolder(elsewhere)
        chmod(elsewhere.path, 0o700)
        try makeLink(places.staging, to: elsewhere)
        #expect(throws: Failure.self) { try HomeRestore.makeStaging(places.staging) }
        HomeRestore.discard(places)
        #expect(exists(elsewhere))
    }
}

@Test func homeRestoreSwapsTheFoldersAndLeavesNoWorkFolder() throws {
    try withScratch { base in
        let home = base.appendingPathComponent("me")
        try makeFile(home.appendingPathComponent("new.txt"))
        let places = HomeRestore.Places(home: home)
        #expect(throws: Failure.self, "nothing was restored") { try HomeRestore.swap(places) }

        try HomeRestore.makeStaging(places.staging)
        try makeFile(places.restored.appendingPathComponent("old.txt"))
        #expect(throws: Failure.self, "a restore that did not finish is in the way") { try HomeRestore.preflight(places, size: nil) }
        try HomeRestore.swap(places)
        #expect(exists(home.appendingPathComponent("old.txt")))
        #expect(exists(places.aside.appendingPathComponent("new.txt")))
        #expect(!exists(places.staging))
        #expect(throws: Failure.self, "the folder set aside is in the way") { try HomeRestore.preflight(places, size: nil) }
    }
}

@Test func homeRestoreDiscardsARestoreThatDoesNotGoOn() throws {
    try withScratch { base in
        let places = HomeRestore.Places(home: base.appendingPathComponent("me"))
        try HomeRestore.makeStaging(places.staging)
        lock(try makeFile(places.restored.appendingPathComponent("Library/locked.txt")))
        HomeRestore.discard(places)
        #expect(!exists(places.staging))
    }
}

@Test func theFolderSetAsideIsEmptiedByItsOwnerOnceTheRestoreIsDone() throws {
    try withScratch { base in
        let home = base.appendingPathComponent("me")
        var state = RestoreState(phase: .waitingForLogout, user: NSUserName(), uid: getuid(), home: home.path,
                                 snapshot: "host/old-mac/2026-11-12T08:00:00Z", archive: "me.pxar")
        let aside = URL(fileURLWithPath: state.aside)
        #expect(aside.path == home.path + ".before-restore")
        let inside = try makeFile(aside.appendingPathComponent("Documents/letter.txt"))
        lock(inside)
        addToACL(aside, "everyone deny delete")

        // Before the swap nothing is set aside.
        #expect(HomeRestore.emptyAside(of: state).isEmpty)
        #expect(exists(inside))
        // Someone else's is not this user's to delete.
        state.phase = .done
        state.uid = getuid() + 1
        #expect(HomeRestore.emptyAside(of: state).isEmpty)
        #expect(exists(inside))

        state.uid = getuid()
        #expect(HomeRestore.emptyAside(of: state).isEmpty)
        #expect(!exists(aside.appendingPathComponent("Documents")))
        // The folder itself lies in /Users, where only root removes it: the daemon, once it is empty.
        #expect(exists(aside))
        #expect(rmdir(aside.path) == 0)
    }
}

@Test func leftoversCountEverythingAndNameTheFirst() {
    var left = Leftovers()
    #expect(left.isEmpty)
    for number in 1...25 { left.add("/Users/me.before-restore/\(number)") }
    #expect(left.count == 25)
    #expect(left.paths.count == 10)
    #expect(left.paths.first == "/Users/me.before-restore/1")
}

@Test func restoreStateKnowsWhereTheRestoreWorks() {
    let state = RestoreState(phase: .restoring, user: "me", uid: 501, home: "/Users/me", snapshot: "s", archive: "me.pxar")
    #expect(state.restored == "/Users/.pbs-mackup-restore-me/me")
    #expect(state.aside == "/Users/me.before-restore")
    #expect(state.places.staging.path == "/Users/.pbs-mackup-restore-me")
}

@Test func theRestoreRightIsTakenBackOnlyAsItWasWritten() {
    // What the authorization database hands back: the rule, and entries of its own.
    var stored: [String: Any] = RestoreService.rightDefinition
    stored["created"] = 784_000_000.5
    stored["modified"] = 784_000_000.5
    stored["version"] = 0
    stored["default-prompt"] = ["": "PBS Mackup wants to restore your home folder from a backup."]
    #expect(RestoreService.isOwnDefinition(stored))
    let stream = try? PropertyListSerialization.data(fromPropertyList: stored, format: .binary, options: 0)
    let decoded = stream.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
    #expect(decoded.map(RestoreService.isOwnDefinition) == true)

    // An administrator's own rule.
    stored["timeout"] = 0
    #expect(!RestoreService.isOwnDefinition(stored))
    #expect(!RestoreService.isOwnDefinition(["class": "rule", "rule": ["authenticate-admin"]]))
    #expect(!RestoreService.isOwnDefinition([:]))
}

@Test func theDaemonHandsTheSecretsBackOnlyToTheOwnerOnceTheFolderIsInPlace() throws {
    let secrets = RestoreSecrets(token: "token", key: Data("key".utf8), passphrase: nil)
    var state = RestoreState(phase: .done, user: "me", uid: 501, home: "/Users/me", snapshot: "s", archive: "me.pxar")
    #expect(try RestoreService.handOver(secrets, of: state, to: 501) == secrets)
    // Not to another user, nor to nobody,
    for asking in [uid_t(502), nil] {
        #expect(throws: (any Error).self) { try RestoreService.handOver(secrets, of: state, to: asking) }
    }
    // not before the swap or after a failure, and not when there is no restore.
    for phase in [RestoreState.Phase.restoring, .waitingForLogout, .failed] {
        state.phase = phase
        #expect(throws: (any Error).self) { try RestoreService.handOver(secrets, of: state, to: 501) }
    }
    #expect(throws: (any Error).self) { try RestoreService.handOver(secrets, of: nil, to: 501) }
    // After a restart the daemon has nothing, and says so.
    state.phase = .done
    let none = #expect(throws: Failure.self) { try RestoreService.handOver(nil, of: state, to: 501) }
    #expect(none?.description.contains("restarted") == true)
}

@Test func theSecretsAreStoredAgainAsTheRunToolTakesThem() throws {
    let plain = Data(#"{"kdf":null,"data":"a2V5","fingerprint":"aa:bb:cc"}"#.utf8)
    let locked = Data(#"{"kdf":{"Scrypt":{"n":65536,"r":8,"p":1,"salt":"c2FsdA=="}},"data":"a2V5","fingerprint":"aa:bb:cc"}"#.utf8)
    let missing = KeyStore.Status(present: false, fingerprint: nil, created: nil)
    let sealed = KeyStore.Status(present: true, fingerprint: "aa:bb:cc", created: nil)
    let foreign = KeyStore.Status(present: true, fingerprint: "dd:ee:ff", created: nil, foreign: true)

    // The token always, and a key where there is none.
    let steps = try RestoreSecrets(token: "secret", key: plain, passphrase: nil).storing(over: missing)
    #expect(steps.map(\.arguments) == [["set-token"], ["set-key"]])
    #expect(steps.map(\.input) == [Data("secret".utf8), plain])
    // A key the app did not put there is replaced, which the run tool has the owner confirm.
    #expect(try RestoreSecrets(token: "secret", key: plain, passphrase: nil).storing(over: foreign).map(\.arguments)
            == [["set-token"], ["set-key"]])
    // The key the app put there stays.
    #expect(try RestoreSecrets(token: "secret", key: plain, passphrase: nil).storing(over: sealed).map(\.arguments) == [["set-token"]])

    // A locked key goes with its passphrase, as `unlock-key` reads it.
    #expect(KeyStore.isLocked(locked))
    let unlocking = try RestoreSecrets(token: "secret", key: locked, passphrase: "pass phrase").storing(over: missing)
    #expect(unlocking.map(\.arguments) == [["set-token"], ["unlock-key"]])
    let sent = try JSONDecoder().decode([String: String].self, from: unlocking[1].input)
    #expect(sent == ["key": String(decoding: locked, as: UTF8.self), "passphrase": "pass phrase"])
    #expect(throws: Failure.self) { try RestoreSecrets(token: "secret", key: locked, passphrase: nil).storing(over: missing) }
}
