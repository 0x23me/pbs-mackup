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

    /// Starts the pbs-mackup-run of the debug build in this home.
    func runTool(_ arguments: [String]) throws -> (status: Int32, output: String, errors: String) {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug/pbs-mackup-run")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["PBS_MACKUP_HOME": folder.path]) { $1 }
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
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

    // What was there before there was a seal is taken over when the app asks for it, once.
    try FileManager.default.removeItem(at: Paths.seal)
    #expect(failure { _ = try Client(config: home.config) } == Seal.keyChanged)
    try Seal.adopt()
    _ = try Client(config: home.config)
    #expect(Seal.holds(home.config))
    try Data("SOMEONE ELSE'S".utf8).write(to: home.folder.appendingPathComponent("secrets/encryption-key"))
    try Seal.adopt()                                                 // not a second time
    #expect(failure { _ = try Client(config: home.config) } == Seal.keyChanged)
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
}
