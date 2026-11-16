import Foundation
import Testing
@testable import PBSMackupKit

// What keeps another program of the owner out: a run goes only by a configuration and a key
// that the app or the run tool stored, and what a restore leaves behind goes away whatever its
// permissions. A script stands in for the client and the server.

/// Answers `snapshot list` with the file `snapshots`. Lists a folder of the snapshot from
/// 14:00 and fails for every other one with what the file `list-error` says. Restores a file
/// by making one of that name, locked as Finder locks a file. Lists a whole archive as the
/// file `names` has it.
private let script = #"""
    #!/bin/sh
    home="$PBS_MACKUP_HOME"
    cat > /dev/null
    echo "$@" >> "$home/client-calls"
    ulimit -Hn > "$home/open-files"
    case "$1 $2" in
        "snapshot list") cat "$home/snapshots" 2>/dev/null || echo "[]" ;;
        "catalog list")
            case "$*" in
                *--recursive*) cat "$home/names" ;;
                *T14:00:05Z*) echo '[{"name":"a.txt","type":"file","mtime":10,"size":1}]' ;;
                *) echo "Error: $(cat "$home/list-error")" >&2; exit 255 ;;
            esac ;;
        "catalog extract")
            /bin/mkdir -p "$6"
            item="$6/$(/usr/bin/basename "$5")"
            printf 'from the backup' > "$item"
            /usr/bin/chflags uchg "$item" ;;
    esac
    """#

private let snapshot = "host/test-mac/2026-11-12T14:00:05Z"

/// A private home with the stand-in client, a stored configuration, a token and a key.
private struct Home {
    let folder: URL
    let config: Config

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("pbs-mackup-hardening-\(UUID().uuidString)")
        let client = folder.appendingPathComponent("bin/proxmox-backup-client")
        try FileManager.default.createDirectory(at: client.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: client)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: client.path)
        setenv("PBS_MACKUP_HOME", folder.path, 1)
        config = Config(repository: "test@pbs!mac@127.0.0.1:1:store", namespace: "test", backupID: "test-mac",
                        sources: [], clientPath: client.path)
        try config.save()
        try Keychain.set(.token, Data("right-token".utf8))
        try Keychain.set(.encryptionKey, Data("KEY".utf8))
    }

    func remove() {
        unsetenv("PBS_MACKUP_HOME")
        tool("/usr/bin/chflags", ["-R", "nouchg", folder.path])
        try? FileManager.default.removeItem(at: folder)
    }

    func write(_ text: String, to name: String) throws {
        try Data(text.utf8).write(to: folder.appendingPathComponent(name))
    }

    /// Starts the pbs-mackup-run of the debug build in this home. `who` says who asks and what
    /// the owner answers, see `asTheApp`; a file stands in for standard input.
    func runTool(_ arguments: [String], _ who: [String: String] = [:], input: Data? = nil) throws -> (status: Int32, output: String, errors: String) {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug/pbs-mackup-run")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["PBS_MACKUP_HOME": folder.path]) { $1 }.merging(who) { $1 }
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        if let input {
            try input.write(to: folder.appendingPathComponent("input"))
            process.standardInput = try FileHandle(forReadingFrom: folder.appendingPathComponent("input"))
        }
        try process.run()
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let complaints = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, printed, complaints)
    }
}

private func failure(_ work: () throws -> Void) -> String? {
    do { try work(); return nil } catch { return "\(error)" }
}

/// Who asks the run tool, said the way a debug build takes it in the place of the helper's
/// connection: the app as macOS has checked it, and whoever connects to the helper of a build no
/// developer signed. Without either, the tool was started as from a terminal.
private let asTheApp = ["PBS_MACKUP_APP": "1"], unchecked = ["PBS_MACKUP_APP": "unchecked"]
/// The owner says no wherever the tool would ask with Touch ID; the error then names the question.
private let saysNo = ["PBS_MACKUP_CONFIRM": "refuse"]

@Test func onlyABuildADeveloperSignedKnowsWhoConnectsToItsHelper() {
    #expect(HelperConnection.checksCaller(signedBy: .team("33C888LZ98")))
    #expect(!HelperConnection.checksCaller(signedBy: .nobody))               // signed ad hoc: anyone can connect
    #expect(!HelperConnection.checksCaller(signedBy: .unknown))
}

@Test func whatAnEarlierVersionKeptInTheCacheIsRemovedOnce() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pbs-mackup-cache-\(UUID().uuidString)")
    let cache = folder.appendingPathComponent("cache"), guarded = folder.appendingPathComponent("group")
    defer { try? FileManager.default.removeItem(at: folder) }
    func fill() throws {
        for name in ["index", "sizes", "preview", "changes"] {
            try FileManager.default.createDirectory(at: cache.appendingPathComponent(name), withIntermediateDirectories: true)
            try Data("Library/Mail".utf8).write(to: cache.appendingPathComponent(name).appendingPathComponent("names.json"))
        }
        for name in ["changed-folders", "settings.json", "run.lock"] { try Data().write(to: cache.appendingPathComponent(name)) }
    }
    try fill()
    // A build without a group container still keeps them there.
    Paths.removeNames(from: cache, nowIn: cache)
    #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).count == 7)
    // With one, the files that hold names go; the lock, the change log's marker and what is open to look at stay.
    Paths.removeNames(from: cache, nowIn: guarded)
    #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).sorted() == ["changes", "preview", "run.lock"])
    Paths.removeNames(from: cache, nowIn: guarded)                          // nothing left to remove
}

@Test func aRequirementNamesOneProgramOfTheDeveloper() {
    let client = Signature.requirementText(team: "33C888LZ98", identifier: "me.0x23.pbs-mackup.client")
    #expect(client == #"anchor apple generic and certificate leaf[subject.OU] = "33C888LZ98" and identifier "me.0x23.pbs-mackup.client""#)
    #expect(Signature.requirement(team: "33C888LZ98", identifier: "me.0x23.pbs-mackup.client") != nil)
    // What is not a name does not become part of a requirement.
    #expect(Signature.requirementText(team: "33C888LZ98", identifier: #"x" or anchor apple or identifier "y"#) == nil)
    #expect(Signature.requirementText(team: "33C888LZ98", identifier: "") == nil)
    #expect(Signature.requirementText(team: #"X" or anchor apple generic or ""#, identifier: "me.0x23.pbs-mackup.client") == nil)
}

@Test func theSameSettingsHaveTheSameDigestHoweverTheyAreWritten() throws {
    let config = Config(repository: "a@pbs!b@host:store", namespace: "mac", backupID: "my-mac", sources: ["/Users/me"], excludes: ["*.iso"])
    let rewritten = try JSONDecoder().decode(Config.self, from: Data(#"""
        { "sources": ["/Users/me"],   "excludes": ["*.iso"], "backupID": "my-mac",
          "namespace": "mac", "frozenSnapshot": "whenPermitted", "repository": "a@pbs!b@host:store", "comment": "mine" }
        """#.utf8))
    #expect(Seal.digest(of: config) == Seal.digest(of: rewritten))
    var other = config
    other.repository = "a@pbs!b@elsewhere:store"
    #expect(Seal.digest(of: config) != Seal.digest(of: other))
    other = config
    other.sources.append("/Users/me/Library/Messages")
    #expect(Seal.digest(of: config) != Seal.digest(of: other))
}

extension PrivateHomeTests {
@Test func aRunGoesOnlyByAConfigurationTheAppStored() throws {
    let home = try Home()
    defer { home.remove() }
    #expect(try home.runTool(["snapshots"]).output == "[]\n")

    // Another program rewrites config.json: other folders, another server.
    var changed = home.config
    changed.repository = "test@pbs!mac@127.0.0.1:2:elsewhere"
    changed.sources = ["/Users/me/Library/Messages"]
    try JSONEncoder().encode(changed).write(to: Paths.config)
    try FileManager.default.removeItem(at: home.folder.appendingPathComponent("client-calls"))
    let refused = try home.runTool(["snapshots"])
    #expect(refused.status == 1)
    #expect(refused.errors == Seal.configChanged + "\n")
    // A run says so in its record, where the menu finds it, and asks no server.
    #expect(try home.runTool(["--manual"]).status == Runner.Exit.notConfigured.rawValue)
    let record = try #require(State.load().last)
    #expect(record.outcome == .failed && record.step == .setup && record.reason == Seal.configChanged)
    #expect(!FileManager.default.fileExists(atPath: home.folder.appendingPathComponent("client-calls").path))

    // The owner looked at it and says it is right: at a terminal with `seal`, in the app with Done.
    #expect(try home.runTool(["seal"]).status == 0)
    #expect(try home.runTool(["snapshots"]).output == "[]\n")
    try home.config.save()
    #expect(Seal.holds(home.config) && !Seal.holds(changed))
}

@Test func aKeyAnotherProgramPutIntoTheKeychainIsNotUsed() throws {
    let home = try Home()
    defer { home.remove() }
    _ = try Client(config: home.config)

    // Any program can delete a Keychain item and put one of its own in its place.
    try Data("SOMEONE ELSE'S".utf8).write(to: home.folder.appendingPathComponent("secrets/encryption-key"))
    #expect(failure { _ = try Client(config: home.config) } == Seal.keyChanged)
    #expect(try home.runTool(["snapshots"]).errors == Seal.keyChanged + "\n")
    _ = try Client(config: home.config, needsKey: false)            // where no key is needed, none is looked at
    #expect(try KeyStore.status().present == false)                 // (this one is no key file at all)

    // A key that goes in through the run tool is the one to go by.
    try Keychain.set(.encryptionKey, Data("NEW".utf8))
    _ = try Client(config: home.config)

}

@Test func withoutASealNothingThatIsThereIsTakenOver() throws {
    let home = try Home()
    defer { home.remove() }
    let key = Data(#"{"kdf":null,"data":"S0VZ","fingerprint":"aa:bb"}"#.utf8)
    try Keychain.set(.encryptionKey, key)
    _ = try Client(config: home.config)

    // The seal is gone, or there never was one: whoever saw to that may have put a
    // configuration and a key of their own in place, so neither is noted just for being there,
    // whatever is started.
    try FileManager.default.removeItem(at: Paths.seal)
    #expect(failure { _ = try Client(config: home.config) } == Seal.keyChanged)
    #expect(try KeyStore.status().foreign)
    #expect(try home.runTool(["setup-status"]).status == 0)
    #expect(try home.runTool(["snapshots"]).errors == Seal.configChanged + "\n")
    #expect(try home.runTool(["--manual"]).status == Runner.Exit.notConfigured.rawValue)
    #expect(!FileManager.default.fileExists(atPath: Paths.seal.path))
    // Taking over what an earlier version left is no command any more.
    let migrate = try home.runTool(["migrate"])
    #expect(migrate.status == 64 && migrate.output.hasPrefix("usage:"))
    #expect(!FileManager.default.fileExists(atPath: Paths.seal.path))

    // The owner says which ones count: the configuration with `seal` or with Done,
    #expect(try home.runTool(["seal"]).status == 0)
    #expect(Seal.holds(home.config) && !Seal.holds(key: key))
    #expect(try home.runTool(["snapshots"]).errors == Seal.keyChanged + "\n")
    // the key by importing the recovery copy.
    #expect(try KeyStore.importKey(key) == KeyStore.Status(present: true, fingerprint: "aa:bb", created: nil))
    #expect(try home.runTool(["snapshots"]).output == "[]\n")
}

@Test func aLockedFileIsRestoredAndStaysLocked() throws {
    let home = try Home()
    defer { home.remove() }
    let client = try Client(config: home.config)
    let target = home.folder.appendingPathComponent("restored")
    func isLocked(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_flags & UInt32(UF_IMMUTABLE) != 0
    }

    let restored = try #require(try client.restore(snapshot: snapshot, archive: "Downloads.pxar", path: "letters/letter.txt", into: target))
    #expect(restored.path == target.appendingPathComponent("letter.txt").path)
    #expect(try String(contentsOf: restored, encoding: .utf8) == "from the backup")
    #expect(isLocked(restored))
    // A second one keeps both; the one that is there is not touched.
    let second = try #require(try client.restore(snapshot: snapshot, archive: "Downloads.pxar", path: "letters/letter.txt", into: target))
    #expect(second.lastPathComponent == "letter 2.txt" && isLocked(second) && isLocked(restored))
    // Nothing of the restore is left beside them.
    #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).sorted() == ["letter 2.txt", "letter.txt"])
}

@Test func whatAStoppedCommandLeftIsRemovedAndWhatIsInUseStays() throws {
    let home = try Home()
    defer { home.remove() }
    try Paths.createFolders()
    func there(_ item: URL) -> Bool { FileManager.default.fileExists(atPath: item.path) }
    /// What a command leaves that is killed, or a Mac that loses power: a key on its way into
    /// the Keychain, and the files of a check, one of them locked as it was backed up.
    func leave() throws -> [URL] {
        let key = Paths.guarded.appendingPathComponent("key-\(UUID().uuidString)")
        let check = Paths.guarded.appendingPathComponent("check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: key, withIntermediateDirectories: true)
        try Data("KEY".utf8).write(to: key.appendingPathComponent("key"))
        let letter = check.appendingPathComponent("0/letter.txt")
        try FileManager.default.createDirectory(at: letter.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("from the backup".utf8).write(to: letter)
        #expect(lchflags(letter.path, UInt32(UF_IMMUTABLE)) == 0)
        return [key, check]
    }
    let left = try leave()

    // A folder this program is using, and one that another program is using: the run tool
    // makes a key, as the helper does for the app, and its client takes its time over it. That
    // command holds no lock a run would wait for.
    let mine = try Scratch(.check)
    try Data("restored".utf8).write(to: mine.folder.appendingPathComponent("file"))
    let slow = home.folder.appendingPathComponent("bin/slow-client")
    try Data(#"""
        #!/bin/sh
        home="$PBS_MACKUP_HOME"
        /usr/bin/dirname "$3" > "$home/key-folder.part"
        /bin/mv "$home/key-folder.part" "$home/key-folder"
        until [ -e "$home/go-on" ]; do sleep 0.05; done
        umask 077
        printf '%s' '{"kdf":null,"data":"bm90IGEgcmVhbCBrZXk=","fingerprint":"aa:bb:cc"}' > "$3"
        """#.utf8).write(to: slow)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slow.path)
    var config = home.config
    config.clientPath = slow.path
    try config.save()
    let making = Process()
    making.executableURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".build/debug/pbs-mackup-run")
    making.arguments = ["create-key", "--replace"]
    making.environment = ProcessInfo.processInfo.environment.merging(["PBS_MACKUP_HOME": home.folder.path]) { $1 }
    making.standardOutput = FileHandle.nullDevice
    making.standardError = FileHandle.nullDevice
    try making.run()
    defer { if making.isRunning { making.terminate() } }
    let noted = home.folder.appendingPathComponent("key-folder")
    for _ in 0..<200 where !there(noted) { usleep(50_000) }
    let theirs = URL(fileURLWithPath: try String(contentsOf: noted, encoding: .utf8).trimmingCharacters(in: .newlines))
    #expect(theirs.lastPathComponent.hasPrefix("key-") && there(theirs))

    Scratch.removeLeftovers()
    #expect(left.allSatisfy { !there($0) })                         // what nobody is using is gone, locked file and all;
    #expect(there(mine.folder.appendingPathComponent("file")))      // what is in use stays, here
    #expect(there(theirs))                                          // and in the other program,
    try Data().write(to: home.folder.appendingPathComponent("go-on"))
    making.waitUntilExit()
    #expect(making.terminationStatus == 0)                          // which makes its key
    #expect(try KeyStore.status().fingerprint == "aa:bb:cc")
    #expect(!there(theirs))                                         // and removes its folder itself.
    mine.remove()
    #expect(!there(mine.folder))

    // A run clears up as well, before it looks at anything else: this one stops at a
    // configuration the app did not store.
    let again = try leave()
    try JSONEncoder().encode(home.config).write(to: Paths.config)
    #expect(try home.runTool(["--manual"]).status == Runner.Exit.notConfigured.rawValue)
    #expect(again.allSatisfy { !there($0) })
    // What else lies there is not touched.
    #expect(there(Paths.clientHome) && there(Paths.lock))
}

@Test func aClientIsStartedWithALimitOnItsOpenFiles() throws {
    let home = try Home()
    defer { home.remove() }
    _ = try Client(config: home.config).snapshots()
    // launchd gives a job no hard limit, and the client keeps that many files open, less a few.
    let limit = try String(contentsOf: home.folder.appendingPathComponent("open-files"), encoding: .utf8)
    #expect((Int(limit.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .max) <= 8192, "\(limit)")
}

@Test func aLinkThatLeadsNowhereStillTakesItsName() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pbs-mackup-names-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("notes.txt").path, withDestinationPath: "gone")
    #expect(Client.freeName(for: "notes.txt", in: folder).lastPathComponent == "notes 2.txt")
    #expect(Client.freeName(for: "other.txt", in: folder).lastPathComponent == "other.txt")
}

@Test func theNamesInASnapshotGoToTheIndexLineByLine() throws {
    let home = try Home()
    defer { home.remove() }
    // As the client lists an archive: one item to a line, the last line without its end.
    try home.write(#"""
        {"path":"Invoices","type":"directory","mtime":1}
        {"path":"Invoices/2026 \"final\".pdf","type":"file","mtime":2,"size":3}
        {"path":"Fotos été/a.jpg","type":"file","mtime":4,"size":5}
        """#, to: "names")
    let client = try Client(config: home.config)
    let file = try client.index(snapshot: snapshot, archives: ["Downloads.pxar", "me.pxar"])
    #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
    let items = try SnapshotIndex(contentsOf: file).items
    #expect(items.count == 6)
    #expect(items.map(\.archive) == ["Downloads.pxar", "Downloads.pxar", "Downloads.pxar", "me.pxar", "me.pxar", "me.pxar"])
    #expect(items[1] == .init(archive: "Downloads.pxar", path: #"Invoices/2026 "final".pdf"#, type: "file", mtime: 2, size: 3))
    #expect(items[3] == .init(archive: "me.pxar", path: "Invoices", type: "directory", mtime: 1, size: nil))
    #expect(items[5].path == "Fotos été/a.jpg")
    // Nothing but the index is left in its folder, and a second asking reads it without the client.
    #expect(try FileManager.default.contentsOfDirectory(atPath: Paths.index.path) == [file.lastPathComponent])
    // The folder is with what no other program is to read, and marked so that no backup takes it.
    #expect(Paths.index.path.hasPrefix(Paths.guarded.path))
    #expect(getxattr(Paths.index.path, SampleCheck.timeMachineExclusion, nil, 0, 0, XATTR_NOFOLLOW) >= 0)
    try FileManager.default.removeItem(at: home.folder.appendingPathComponent("client-calls"))
    #expect(try client.index(snapshot: snapshot, archives: ["Downloads.pxar", "me.pxar"]) == file)
    #expect(!FileManager.default.fileExists(atPath: home.folder.appendingPathComponent("client-calls").path))
}

@Test func theVersionsOfAFileAreNotCutShortByAnError() throws {
    let home = try Home()
    defer { home.remove() }
    let formatter = ISO8601DateFormatter()
    let times = try ["2026-11-12T14:00:05Z", "2026-11-12T15:00:05Z"].map { Int(try #require(formatter.date(from: $0)).timeIntervalSince1970) }
    try home.write("[" + times.map {
        #"{"backup-type":"host","backup-id":"test-mac","backup-time":\#($0),"files":[{"filename":"Downloads.pxar.didx"}],"size":1}"#
    }.joined(separator: ",") + "]", to: "snapshots")
    let client = try Client(config: home.config)

    // The later snapshot has no such folder: the file has one version, from the earlier one.
    try home.write("no such path in Downloads.pxar.didx: letters", to: "list-error")
    #expect(try client.versions(archive: "Downloads.pxar", path: "letters/a.txt").map(\.snapshot) == [snapshot])
    // The server goes away while the snapshots are looked through: that is said, not shown as a shorter list.
    try home.write("connection refused", to: "list-error")
    #expect(failure { _ = try client.versions(archive: "Downloads.pxar", path: "letters/a.txt") } == "connection refused")
}

@Test func aCommandAnswersOnlyTheCallersItsEntryNames() throws {
    let home = try Home()
    defer { home.remove() }
    // The app gets what the Backups window and the settings ask for,
    #expect(try home.runTool(["snapshots"], asTheApp).output == "[]\n")
    #expect(try home.runTool(["setup-status"], asTheApp).status == 0)
    // and nothing else: no run, no helper, nothing that is for a terminal or for root. Whoever
    // connects to the helper of a build no developer signed gets no more than the app.
    for who in [asTheApp, unchecked] {
        for arguments in [[], ["--manual"], ["--full"], ["serve"], ["status"], ["check"], ["seal"],
                          ["certificate", "127.0.0.1", "1"], ["restore-daemon"], ["restore-home", "me", "repository", "key.json"]] {
            let refused = try home.runTool(arguments, who)
            #expect(refused.status == 1 && refused.output.isEmpty, "\(arguments)")
            #expect(refused.errors == "\(arguments.first ?? "A backup run") is started from a terminal or by launchd, not by the app.\n")
        }
    }
    #expect(State.load().last == nil)                               // no run left a record
    #expect(try home.runTool(["status"]).output == "no run yet\n")  // which a terminal may ask for

    // What is for root says so to anyone else, with how it is used, and does nothing.
    try #require(geteuid() != 0)
    for name in ["restore-daemon", "restore-home"] {
        let refused = try home.runTool([name, "me", "repository", "key.json"])
        #expect(refused.status == 1)
        #expect(refused.errors.hasPrefix("\(name) needs root.\nusage:\n  pbs-mackup-run \(name)"), "\(refused.errors)")
    }
}

@Test func theOwnerConfirmsForEveryoneButTheAppMacOSHasChecked() throws {
    let home = try Home()
    defer { home.remove() }
    let folder = home.folder.appendingPathComponent("bin").path
    let key = Data(#"{"kdf":null,"created":"2026-01-02T03:04:05+01:00","data":"bm90IGEgcmVhbCBrZXk=","fingerprint":"aa:bb:cc"}"#.utf8)
    let stored = home.folder.appendingPathComponent("secrets/encryption-key")

    // Started as a program, and over the helper of a build no developer signed, where any
    // program of the owner can be at the other end: nothing is read before the owner said yes.
    for who in [[:], unchecked] {
        let asked = who.merging(saysNo) { $1 }
        #expect(try home.runTool(["snapshots"], asked).errors == "Not confirmed: list your backups\n")
        #expect(try home.runTool(["list", snapshot, "Downloads.pxar"], asked).errors == "Not confirmed: read the names in your backups\n")
        #expect(try home.runTool(["restore", snapshot, "Downloads.pxar", "a.txt", home.folder.path], asked).errors
                == "Not confirmed: restore files from your backups\n")
        #expect(!FileManager.default.fileExists(atPath: home.folder.appendingPathComponent("client-calls").path))   // no client was started
        // Measuring reads the names in any folder the tool can read.
        #expect(try home.runTool(["sizes", folder], asked).errors == "Not confirmed: read the names and sizes of what is in your folders\n")
        #expect(FolderSizes.load(for: folder) == nil)
        // What gives nothing away asks nothing.
        #expect(try home.runTool(["setup-status"], asked).status == 0)
        // And with a yes it is done.
        #expect(try home.runTool(["snapshots"], who).output == "[]\n")
        try FileManager.default.removeItem(at: home.folder.appendingPathComponent("client-calls"))
    }

    // The app is not asked,
    let app = asTheApp.merging(saysNo) { $1 }
    #expect(try home.runTool(["snapshots"], app).output == "[]\n")
    #expect(try home.runTool(["sizes", folder], app).status == 0)
    #expect(FolderSizes.load(for: folder) != nil)
    // except before a key takes the place of another.
    #expect(try home.runTool(["set-key"], app, input: key).errors == "Not confirmed: replace the encryption key of your backups\n")
    #expect(try Data(contentsOf: stored) == Data("KEY".utf8))

    // A first key from the app goes in without a question; from anyone else it is confirmed.
    try FileManager.default.removeItem(at: stored)
    for who in [[:], unchecked] {
        #expect(try home.runTool(["set-key"], who.merging(saysNo) { $1 }, input: key).errors == "Not confirmed: set the encryption key of your backups\n")
        #expect(!FileManager.default.fileExists(atPath: stored.path))
    }
    #expect(try home.runTool(["set-key"], app, input: key).output.contains(#""fingerprint":"aa:bb:cc""#))
    #expect(try Data(contentsOf: stored) == key)

    // The token the app stores after a restore of the home folder goes in without a question;
    // from anyone else it is confirmed.
    let token = home.folder.appendingPathComponent("secrets/token")
    for who in [[:], unchecked] {
        #expect(try home.runTool(["set-token"], who.merging(saysNo) { $1 }, input: Data("other".utf8)).errors
                == "Not confirmed: replace the API token of your backups\n")
    }
    #expect(try home.runTool(["set-token"], app, input: Data("restored".utf8)).output == #"{"stored":"token"}"# + "\n")
    #expect(try Data(contentsOf: token) == Data("restored".utf8))
}
}

@Test func aProgramTheOwnerConfirmedIsKnownUntilItEnds() throws {
    var callers = ConfirmedCallers()
    #expect(!callers.holds(getpid()))
    callers.note(getpid())
    #expect(callers.holds(getpid()))
    // Another program is asked about anew, and so is whatever gets the id of one that has ended.
    let other = try Child(URL(fileURLWithPath: "/bin/sleep"), ["30"])
    #expect(!callers.holds(other.pid))
    callers.note(other.pid)
    #expect(callers.holds(other.pid))
    other.signal(SIGKILL)
    other.wait()
    #expect(!callers.holds(other.pid))
    #expect(callers.holds(getpid()))
}
