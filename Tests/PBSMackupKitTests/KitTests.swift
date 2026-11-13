import Foundation
import Testing
@testable import PBSMackupKit

@Test func serverIsReadFromTheRepository() {
    func server(_ repository: String) -> String? {
        Config(repository: repository, namespace: "", backupID: "", sources: []).server.map { "\($0.host) \($0.port)" }
    }
    #expect(server("backup@pbs!mac@pbs.example.net:store") == "pbs.example.net 8007")
    #expect(server("backup@pbs!mac@192.0.2.6:8008:store") == "192.0.2.6 8008")
    #expect(server("backup@pbs@[fd00::6]:8007:store") == "fd00::6 8007")
    #expect(server("store") == nil)
}

@Test func archiveNamesComeFromTheFolder() {
    #expect(Config.archiveName(for: "/Users/me/Downloads") == "Downloads.pxar")
    #expect(Config.archiveName(for: "/Users/me/My Files (old)") == "My_Files__old_.pxar")
}

@Test func firstRunOutputIsRead() {
    var output = ClientOutput()
    var progressLines = 0
    for line in """
        Starting backup: [mac]:host/my-mac/2026-11-11T22:22:48Z
        No previous manifest available.
        {"type":"progress","entries":3,"bytes_processed":4000000,"bytes_uploaded":1000,"path":"a/b.txt","elapsed":1.0}
        {"type":"progress","entries":8,"bytes_processed":8000000,"bytes_uploaded":2000,"path":"c d/é.txt","elapsed":2.0}
        downloads.mpxar: had to backup 1021.469 KiB of 1021.469 KiB (compressed 81.099 KiB) in 296.01 s (average 3.45 KiB/s)
        downloads.ppxar: had to backup 41.585 GiB of 43.078 GiB (compressed 31.853 GiB) in 296.19 s (average 143.769 MiB/s)
        downloads.ppxar: backup was done incrementally, reused 1.494 GiB (3.5%)
        Duration: 297.04s
        {"type":"result","ok":true,"snapshot":"host/my-mac/2026-11-11T22:22:48Z","namespace":"mac","entries":1474,"bytes_processed":46254325760,"bytes_reused":1604000000,"bytes_uploaded":44651675648,"skipped_placeholders":["iCloud/draft.pages"],"skipped_placeholder_count":1,"time_machine_excluded":3,"warnings":[],"duration":297.04}
        """.split(separator: "\n") where output.read(String(line)) { progressLines += 1 }
    #expect(output.snapshot == "host/my-mac/2026-11-11T22:22:48Z")
    #expect(progressLines == 2)
    #expect(output.progress == ClientOutput.ProgressRecord(entries: 8, bytesProcessed: 8_000_000, bytesUploaded: 2000,
                                                          path: "c d/é.txt", elapsed: 2.0))
    #expect(output.result.entries == 1474)
    #expect(output.result.bytesProcessed == 46_254_325_760)
    #expect(output.result.bytesUploaded == 44_651_675_648)
    #expect(output.result.skippedPlaceholders == ["iCloud/draft.pages"])
    #expect(output.result.skippedPlaceholderCount == 1)
    #expect(output.result.timeMachineExcluded == 3)
    #expect(output.result.archives.map(\.name) == ["downloads.mpxar", "downloads.ppxar"])
    #expect(output.result.archives[1].uploaded == "41.585 GiB")
    #expect(output.result.archives[1].total == "43.078 GiB")
    #expect(output.result.archives[1].reused == "1.494 GiB (3.5%)")
    #expect(output.result.clientDuration == "297.04s")
}

@Test func unchangedRunOutputIsRead() {
    var output = ClientOutput()
    for line in """
        Starting backup: host/my-mac/2026-11-11T22:28:00Z
        Change detection summary:
         - 1291 total files (0 hardlinks)
         - 1291 unchanged, reusable files with 43.078 GiB data
         - 0 changed or non-reusable files with 0 B data
        downloads.ppxar: had to backup 32 B of 43.078 GiB (compressed 120 B) in 0.54 s (average 59 B/s)
        Error: something went wrong
        """.split(separator: "\n") { output.read(String(line)) }
    #expect(output.snapshot == "host/my-mac/2026-11-11T22:28:00Z")
    #expect(output.result.totalFiles == 1291)
    #expect(output.result.unchangedFiles == 1291)
    #expect(output.result.changedFiles == 0)
    #expect(output.result.archives.first?.uploaded == "32 B")
    #expect(output.result.error == "something went wrong")
}

@Test func stateCountsFailuresAndKeepsTheLastSuccess() throws {
    func record(_ outcome: Outcome) -> RunRecord {
        RunRecord(start: Date(timeIntervalSince1970: 1_800_000_000), end: Date(timeIntervalSince1970: 1_800_000_060),
                  trigger: .scheduled, outcome: outcome, reason: nil, step: nil, snapshot: nil, frozen: true,
                  result: BackupResult(), log: nil)
    }
    var state = State()
    state.finish(record(.success))
    state.finish(record(.failed))
    state.finish(record(.skipped))
    state.finish(record(.failed))
    #expect(state.consecutiveFailures == 2)       // a skipped run neither counts nor resets
    #expect(state.lastSuccess?.outcome == .success)
    #expect(state.last?.outcome == .failed)
    state.finish(record(.success))
    #expect(state.consecutiveFailures == 0)

    let file = FileManager.default.temporaryDirectory.appendingPathComponent("pbs-mackup-state-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    try state.save(to: file)
    #expect(State.load(from: file) == state)
}

@Test func theBatteryIsAskedOfTheSystem() {
    // Whatever Mac this runs on: a charge between empty and full, or no battery at all.
    if let battery = Power.battery() { #expect((0...100).contains(battery.percent)) }
}

@Test func folderArchivesAreFoundAmongSnapshotFiles() {
    let files = ["Downloads.mpxar.didx", "Downloads.ppxar.didx", "native-macos-payloads-0.pxar.didx",
                 "macos-metadata.json.blob", "index.json.blob", "Documents.pxar.didx", "catalog.pcat1.didx"]
    #expect(Client.archives(in: files) == ["Documents.pxar", "Downloads.pxar"])
}

@Test func mountFoldersSayWhatTheyShow() {
    let folder = Client.mountFolder(snapshot: "host/my-mac/2026-11-12T14:00:05Z", archive: "Downloads.pxar")
    #expect(folder.lastPathComponent == "Downloads 2026-11-12 14.00.05")
    #expect(folder.deletingLastPathComponent().lastPathComponent == "browse")
    #expect(!Client.isMounted(FileManager.default.temporaryDirectory.appendingPathComponent("pbs-mackup-not-there")))
    #expect(!Client.isMounted(URL(fileURLWithPath: NSHomeDirectory())))
    #expect(Client.isMounted(URL(fileURLWithPath: "/dev")))
}

@Test func searchFindsNamesAndPutsTheBestFirst() {
    func item(_ path: String, _ type: String = "file") -> SnapshotIndex.Item {
        .init(archive: "Downloads.pxar", path: path, type: type, mtime: 0, size: 1)
    }
    let index = SnapshotIndex(items: [
        item("readme.md"), item("archive/old-invoices.zip"), item("notes/vat invoice.txt"),
        item("Invoices/2026/Invoice March.pdf"), item("Invoices", "directory"),
        item("Fotos/Zürich été.jpg"), item("Fotos/Zu\u{308}rich nfd.jpg"),
        item("39c3-1785-deu-eng-Building_a_NOC_from_scratch.mp4"),
    ])
    func found(_ query: String) -> [String] { index.search(query).items.map(\.path) }

    // Names that start with the word, then names where it starts a part; shorter paths first.
    #expect(found("invoice") == ["Invoices", "Invoices/2026/Invoice March.pdf", "notes/vat invoice.txt", "archive/old-invoices.zip"])
    // Case, accents and the way a letter is composed make no difference.
    #expect(Set(found("zurich")) == ["Fotos/Zürich été.jpg", "Fotos/Zu\u{308}rich nfd.jpg"])
    #expect(found("ZÜRICH ete") == ["Fotos/Zürich été.jpg"])
    // Every word has to match; a word may match a folder above.
    #expect(found("2026 march") == ["Invoices/2026/Invoice March.pdf"])
    #expect(found("noc 39c3") == ["39c3-1785-deu-eng-Building_a_NOC_from_scratch.mp4"])
    // Letters in order, with little in between.
    #expect(found("invpdf") == ["Invoices/2026/Invoice March.pdf"])
    #expect(found("rdm") == ["readme.md"])
    #expect(found("nothing like this").isEmpty)
    #expect(found("   ").isEmpty)

    let few = index.search("i", limit: 2)
    #expect(few.items.count == 2 && few.total > 2)
}

@Test func searchResultsBecomeRowsWithTheirFolder() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("pbs-mackup-index-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let items = [SnapshotIndex.Item(archive: "Downloads.pxar", path: "a/b/c.txt", type: "file", mtime: 5, size: 7)]
    try JSONEncoder().encode(items).write(to: file)
    #expect(try SnapshotIndex(contentsOf: file).items == items)
    #expect(Client.indexFile(snapshot: "host/my-mac/2026-11-12T14:00:05Z").lastPathComponent == "host-my-mac-2026-11-12T14.00.05Z.json")
}

@Test func restoreNeverTakesAnExistingName() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pbs-mackup-names-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(Client.freeName(for: "report.pdf", in: folder).lastPathComponent == "report.pdf")
    for name in ["report.pdf", "report 2.pdf", "notes"] {
        FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: nil)
    }
    #expect(Client.freeName(for: "report.pdf", in: folder).lastPathComponent == "report 3.pdf")
    #expect(Client.freeName(for: "notes", in: folder).lastPathComponent == "notes 2")
}

@Test func onlyScheduledRunsWaitForPower() {
    func skip(_ trigger: Trigger, _ percent: Int, onAC: Bool, lowPower: Bool = false) -> Bool {
        Runner.batterySkip(trigger: trigger, battery: (percent, onAC), lowPowerMode: lowPower) != nil
    }
    #expect(skip(.scheduled, 15, onAC: false))
    #expect(skip(.scheduled, 60, onAC: false, lowPower: true))
    #expect(!skip(.scheduled, 60, onAC: false))
    #expect(!skip(.scheduled, 15, onAC: true))
    #expect(!skip(.manual, 5, onAC: false, lowPower: true))
    #expect(Runner.batterySkip(trigger: .scheduled, battery: nil, lowPowerMode: true) == nil)   // no battery
}

@Test func logsOlderThanThirtyDaysAreRemoved() throws {
    let logs = FileManager.default.temporaryDirectory.appendingPathComponent("pbs-mackup-logs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: logs) }
    let now = Date()
    for (name, age) in [("old.log", 31.0), ("recent.log", 29.0)] {
        let file = logs.appendingPathComponent(name)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age * 86400)], ofItemAtPath: file.path)
    }
    Runner.removeOldLogs(in: logs, now: now)
    #expect(try FileManager.default.contentsOfDirectory(atPath: logs.path) == ["recent.log"])
}

private func record(_ outcome: Outcome, at start: Date, reason: String? = nil) -> RunRecord {
    RunRecord(start: start, end: start.addingTimeInterval(60), trigger: .scheduled, outcome: outcome, reason: reason,
              step: nil, snapshot: nil, frozen: true, result: BackupResult(), log: nil)
}

@Test func threeFailuresGiveOneNoticeUntilABackupSucceeds() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var state = State(), notices = Notices()
    state.finish(record(.success, at: start))
    for hour in 1...2 {
        state.finish(record(.failed, at: start.addingTimeInterval(Double(hour) * 3600), reason: "The datastore is full."))
        #expect(notices.check(state, now: start.addingTimeInterval(Double(hour) * 3600)) == nil)
    }
    state.finish(record(.failed, at: start.addingTimeInterval(3 * 3600), reason: "The datastore is full."))
    let notice = notices.check(state, now: start.addingTimeInterval(3 * 3600))
    #expect(notice?.title == "Backups are failing")
    #expect(notice?.body == "The last 3 backups failed. The datastore is full.")
    state.finish(record(.failed, at: start.addingTimeInterval(4 * 3600)))
    #expect(notices.check(state, now: start.addingTimeInterval(4 * 3600)) == nil)        // said once

    state.finish(record(.success, at: start.addingTimeInterval(5 * 3600)))
    #expect(notices.check(state, now: start.addingTimeInterval(5 * 3600)) == nil)
    for hour in 6...8 { state.finish(record(.failed, at: start.addingTimeInterval(Double(hour) * 3600))) }
    #expect(notices.check(state, now: start.addingTimeInterval(8 * 3600))?.title == "Backups are failing")   // and again after a success
}

@Test func skippedRunsAreQuietUntilThreeDaysWithoutABackup() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var state = State(), notices = Notices()
    state.finish(record(.success, at: start))
    for hour in 1...48 {     // two days away from the server
        state.finish(record(.skipped, at: start.addingTimeInterval(Double(hour) * 3600), reason: "The server is not reachable."))
        #expect(notices.check(state, now: start.addingTimeInterval(Double(hour) * 3600)) == nil)
    }
    #expect(state.consecutiveFailures == 0)
    let later = start.addingTimeInterval(3 * 86400 + 3600)
    #expect(notices.check(state, now: later)?.title == "No backup for three days")
    #expect(notices.check(state, now: later.addingTimeInterval(3600)) == nil)             // said once
    state.finish(record(.success, at: later.addingTimeInterval(7200)))
    #expect(notices.check(state, now: later.addingTimeInterval(7300)) == nil)
}

@Test func aFileEditedOnThreeDaysHasThreeVersions() {
    func snapshot(_ day: Int, _ hour: Int) -> Client.Snapshot {
        let time = Date(timeIntervalSince1970: 1_800_000_000 + Double(day) * 86400 + Double(hour) * 3600)
        return Client.Snapshot(name: "host/mac/d\(day)h\(hour)", time: time, archives: ["Documents.pxar"], size: nil)
    }
    func entry(_ mtime: Int64, _ size: Int64) -> Client.Entry { Client.Entry(name: "notes.txt", type: "file", mtime: mtime, size: size) }
    // Newest first, as the server lists them. The file does not exist on day 0 and changes on days 1, 2 and 4.
    let seen: [(snapshot: Client.Snapshot, entry: Client.Entry?)] = [
        (snapshot(5, 9), entry(400, 30)), (snapshot(4, 18), entry(400, 30)), (snapshot(4, 9), entry(200, 20)),
        (snapshot(3, 9), entry(200, 20)), (snapshot(2, 18), entry(200, 20)), (snapshot(2, 9), entry(100, 10)),
        (snapshot(1, 18), entry(100, 10)), (snapshot(0, 9), nil),
    ]
    let versions = Client.versions(in: seen)
    #expect(versions.map(\.snapshot) == ["host/mac/d4h18", "host/mac/d2h18", "host/mac/d1h18"])
    #expect(versions.map(\.modified) == [400, 200, 100])
    #expect(versions.map(\.size) == [30, 20, 10])
}

@Test func theSampleLeavesOutWhatTheBackupLeavesOut() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pbs-mackup-pick-\(UUID().uuidString)")
    defer { chmod(root.appendingPathComponent("closed.txt").path, 0o600); try? FileManager.default.removeItem(at: root) }
    for folder in ["sub", "Library/Caches", "marked", "sub/Library/Caches"] {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
    }
    for file in ["a.txt", "sub/b.txt", ".DS_Store", "sub/.DS_Store", "Library/Caches/c.bin", "marked/d.txt", "closed.txt",
                 "sub/Library/Caches/kept.txt"] {
        try Data("x".utf8).write(to: root.appendingPathComponent(file))
    }
    setxattr(root.appendingPathComponent("marked").path, SampleCheck.timeMachineExclusion, "x", 1, 0, 0)
    chmod(root.appendingPathComponent("closed.txt").path, 0)
    var seen = Set<String>()
    for _ in 0..<40 { seen.formUnion(SampleCheck.pick(in: root, count: 10, maxBytes: 1000)) }
    // Library/Caches only counts at the top of the folder; deeper down it is an ordinary folder.
    #expect(seen == ["a.txt", "sub/b.txt", "sub/Library/Caches/kept.txt"])
}

@Test func foldersAreMeasuredAsOnDiskWithWhatTheBackupLeavesOut() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sizes-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    func write(_ path: String, megabytes: Int) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Not all zeros, so the size on disk is the size.
        try Data((0..<megabytes << 20).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: file)
    }
    try write("work/report.bin", megabytes: 3)
    try write("work/project/node_modules/lib.bin", megabytes: 2)
    try write("work/small.txt", megabytes: 0)
    try write(".Trash/old.bin", megabytes: 1)
    try write("vm/disk.img", megabytes: 2)
    try write("Library/Caches/thing.bin", megabytes: 1)
    #expect(tool("/bin/cp", ["-c", root.path + "/work/report.bin", root.path + "/work/report copy.bin"]).status == 0)
    #expect(link(root.path + "/work/report.bin", root.path + "/work/report link.bin") == 0)
    #expect(tool("/usr/bin/xattr", ["-w", SampleCheck.timeMachineExclusion, "x", root.path + "/vm"]).status == 0)

    let megabyte: Int64 = 1 << 20
    let sizes = try FolderSizes.measure(root.path, smallest: megabyte)
    #expect(sizes.root.bytes == 12 * megabyte)          // the copy counts like Finder counts it, the second name does not
    #expect(sizes.root.shared == 3 * megabyte)
    #expect(sizes.root.leftOut == 4 * megabyte)         // the trash, the marked folder and the caches
    #expect(sizes.root.files == 7)
    #expect(sizes.unreadable == 0)
    #expect(sizes.names["node_modules"] == .init(count: 1, bytes: 2 * megabyte))
    #expect(sizes.root.children.map(\.name) == ["work", "vm", ".Trash", "Library"])
    #expect(sizes.root.children.map(\.reason) == [nil, .timeMachine, .always, nil])
    let work = try #require(sizes.root.children.first)
    #expect(work.children.map(\.name) == ["report copy.bin", "report.bin", "project"]
            || work.children.map(\.name) == ["report copy.bin", "report link.bin", "project"])

    // What the owner's rules make of it.
    #expect(LeaveOut.tally(sizes, rules: []) == .init(backedUp: 8 * megabyte, byRules: 0, automatic: 4 * megabyte, shared: 3 * megabyte))
    let rules = ["node_modules", LeaveOut.rule(forPath: "work/report copy.bin")]
    #expect(LeaveOut.tally(sizes, rules: rules).byRules == 5 * megabyte)
    let rows = LeaveOut.items(sizes, rules: rules)
    #expect(rows.map(\.state) == [.partly, .automatic(.timeMachine), .automatic(.always), .partly])
    let workRows = try #require(rows.first?.children)
    #expect(workRows.first { $0.name == "report copy.bin" }?.state == .leftOut(rule: "/work/report copy.bin", own: true))
    let project = try #require(workRows.first { $0.name == "project" })
    #expect(project.children?.first?.state == .leftOut(rule: "node_modules", own: false))
    #expect(project.backedUp == 0)
}

@Test func rulesNameOneItemOrANameAnywhere() {
    #expect(LeaveOut.rule(forPath: "code/what? [old]*") == "/code/what\\? \\[old]\\*")
    #expect(LeaveOut.path(of: "/code/what\\? \\[old]\\*") == "code/what? [old]*")
    #expect(LeaveOut.path(of: "/code/*/target") == nil)
    #expect(LeaveOut.path(of: "node_modules") == nil)
    #expect(LeaveOut.matches("/Movies", relative: "Movies"))
    #expect(!LeaveOut.matches("/Movies", relative: "code/Movies"))
    #expect(!LeaveOut.matches("/Movies", relative: "Movies/2024"))      // the folder is left out, so what is below never comes up
    #expect(LeaveOut.matches("node_modules", relative: "code/app/node_modules"))
    #expect(!LeaveOut.matches("node_modules", relative: "code/node_modules_old"))
    #expect(LeaveOut.matches("*.iso", relative: "Downloads/ubuntu.iso"))
    #expect(LeaveOut.matches("/code/*/target", relative: "code/app/target"))
    #expect(!LeaveOut.matches("/code/*/target", relative: "code/a/b/target"))
    #expect(LeaveOut.matches("app/build", relative: "code/app/build"))
    #expect(!LeaveOut.matches("!keep", relative: "keep"))
}

@Test func suggestionsAreWhatCanBeMadeAgainAndIsNotLeftOutYet() {
    let gigabyte: Int64 = 1 << 30
    func folder(_ name: String, _ bytes: Int64, _ children: [FolderSizes.Node] = [], reason: FolderSizes.Reason? = nil) -> FolderSizes.Node {
        .init(name: name, isFolder: true, bytes: bytes, leftOut: reason == nil ? 0 : bytes, files: 1, reason: reason, children: children)
    }
    let root = folder("/Users/x", 40 * gigabyte, [
        folder("code", 20 * gigabyte, [folder("app", 12 * gigabyte, [folder("node_modules", 9 * gigabyte)])]),
        folder(".npm", 4 * gigabyte),
        folder("Library", 10 * gigabyte, [folder("Caches", 6 * gigabyte, reason: .always), folder("Logs", 1 << 20)]),
    ])
    var root2 = root
    root2.leftOut = 6 * gigabyte
    root2.children[2].leftOut = 6 * gigabyte
    let sizes = FolderSizes(path: "/Users/x", root: root2, measured: Date(), unreadable: 0, cloudOnly: 0,
                            names: ["node_modules": .init(count: 3, bytes: 9 * gigabyte), ".venv": .init(count: 1, bytes: 1 << 20)])
    let found = Suggestions.find(in: sizes, rules: [])
    #expect(found.map(\.rule) == ["node_modules", "/.npm"])
    #expect(found.first?.bytes == 9 * gigabyte)
    #expect(found.first?.title == "Folders named node_modules")
    #expect(found.first?.detail.hasPrefix("3 folders · ") == true)
    #expect(found.last?.detail == "~/.npm · npm fetches them again")
    #expect(Suggestions.find(in: sizes, rules: ["node_modules", "/.npm"]).isEmpty)
    #expect(LeaveOut.tally(sizes, rules: ["node_modules", "/.npm"])
            == .init(backedUp: 21 * gigabyte, byRules: 13 * gigabyte, automatic: 6 * gigabyte, shared: 0))
}

@Test func theChangeLogNamesWhatChangedAndNothingElse() throws {
    // Not under /var/folders: nothing else should write here while the test looks.
    let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/pbs-mackup-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = FileManager.default
    for folder in ["data/quiet/deep", "data/edited", "data/old name/inside", "data/gets a file", "marker"] {
        try manager.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
    }
    try Data("one".utf8).write(to: root.appendingPathComponent("data/edited/file.txt"))
    try Data("one".utf8).write(to: root.appendingPathComponent("data/quiet/deep/file.txt"))
    let data = root.appendingPathComponent("data").path
    let marker = root.appendingPathComponent("marker")

    // Nothing after the position: nothing reported, even though the folders were just made.
    usleep(1_500_000)
    let start = try #require(ChangeLog.position(of: data))
    #expect(ChangeLog.changes(below: [data], since: start, marker: marker) == .changes(.init()))

    try Data("two".utf8).write(to: root.appendingPathComponent("data/edited/file.txt"))
    try Data("new".utf8).write(to: root.appendingPathComponent("data/gets a file/new.txt"))
    try manager.moveItem(at: root.appendingPathComponent("data/old name"), to: root.appendingPathComponent("data/new name"))
    try manager.createDirectory(at: root.appendingPathComponent("data/made"), withIntermediateDirectories: false)
    guard case .changes(let changes) = ChangeLog.changes(below: [data], since: start, marker: marker) else {
        Issue.record("the change log gave no answer"); return
    }
    #expect(changes.folders == [data, data + "/edited", data + "/gets a file"])
    #expect(changes.subtrees == [data + "/old name", data + "/new name", data + "/made"])
    #expect(String(decoding: changes.records(prefix: "/mnt"), as: UTF8.self).split(separator: "\0").map(String.init)
            == ["r/mnt\(data)/made", "r/mnt\(data)/new name", "r/mnt\(data)/old name",
                "d/mnt\(data)", "d/mnt\(data)/edited", "d/mnt\(data)/gets a file"])

    // A later position leaves the earlier changes out.
    let later = try #require(ChangeLog.position(of: data))
    #expect(ChangeLog.changes(below: [data], since: later, marker: marker) == .changes(.init()))
    // A position from another log, or ahead of this one, is no basis.
    #expect(ChangeLog.changes(below: [data], since: .init(event: start.event, log: "other"), marker: marker)
            == .unusable("macOS started its change log over"))
    #expect(ChangeLog.changes(below: [data], since: .init(event: later.event + 1_000_000_000, log: later.log), marker: marker)
            == .unusable("the remembered position is ahead of the change log"))
}

@Test func aScheduledRunWaitsForTheInterval() {
    let last = Date(timeIntervalSince1970: 1_800_000_000)
    var state = State()
    #expect(Runner.isDue(state, intervalMinutes: 60, now: last))
    state.finish(record(.success, at: last))
    #expect(!Runner.isDue(state, intervalMinutes: 60, now: last.addingTimeInterval(55 * 60)))
    #expect(Runner.isDue(state, intervalMinutes: 60, now: last.addingTimeInterval(60 * 60 - 10)))     // launchd's timer is not exact
    #expect(Runner.isDue(state, intervalMinutes: 15, now: last.addingTimeInterval(15 * 60)))
    #expect(Config(repository: "", namespace: "", backupID: "", sources: []).interval == 60)
}

@Test func theClientSaysWhatItTookOverWithoutReading() {
    var output = ClientOutput()
    output.read(#"{"type":"result","ok":true,"snapshot":"host/x/2026-11-12T17:00:00Z","entries":10,"carried_dirs":7,"walked_dirs":2,"change_list":"used"}"#)
    #expect(output.result.carriedFolders == 7)
    #expect(output.result.readFolders == 2)
    #expect(output.result.changeList == "used")
}

@Test func fullDiskAccessIsSeenWhereThisMacKeepsItsPermissions() {
    // The tests run with what the terminal has; the answer has to agree with a file only
    // Full Disk Access opens, wherever this version of macOS keeps it.
    let file = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
    if file >= 0 { close(file) }
    #expect(FullDiskAccess.granted == (file >= 0))
}

@Test func theUploadSpeedIsSteadyWhileChunksArriveInBursts() {
    var speed = UploadSpeed()
    #expect(speed.add(bytes: 0, at: 0) == nil)
    #expect(speed.add(bytes: 0, at: 1) == nil)               // too little to go by
    // 100 MB every second, arriving as 200 MB every other second.
    var seen: [Double] = []
    for second in 2...30 {
        let bytes = Int64(second / 2 * 2) * 100_000_000
        if let now = speed.add(bytes: bytes, at: Double(second)), second >= 12 { seen.append(now) }
    }
    #expect(seen.allSatisfy { abs($0 - 800_000_000) < 100_000_000 })   // 0.8 Gbit/s, give or take an eighth
    #expect(UploadSpeed.text(seen.last ?? 0) == "0.80 Gbit/s")
    // The upload stops: the speed falls to nothing within the window, and the text goes away.
    var last: Double?
    for second in 31...45 { last = speed.add(bytes: 3_000_000_000, at: Double(second)) }
    #expect(last == 0)
    #expect(UploadSpeed.text(0) == nil)
    #expect(UploadSpeed.text(42_000_000) == "42 Mbit/s")
    #expect(UploadSpeed.text(3_400_000) == "3.4 Mbit/s")
    #expect(UploadSpeed.text(130_000_000) == "0.13 Gbit/s")
    #expect(UploadSpeed.text(2_500_000_000) == "2.50 Gbit/s")
    // A count that starts over is a new upload, not a negative speed.
    #expect(speed.add(bytes: 10, at: 46) == nil)
}

@Test func progressCarriesWhatWentOverTheNetwork() {
    var output = ClientOutput()
    output.read(#"{"type":"progress","entries":3,"bytes_processed":4000,"bytes_uploaded":1000,"bytes_sent":700,"path":"a","elapsed":1.0}"#)
    #expect(output.progress?.bytesSent == 700)
    output.read(#"{"type":"progress","entries":3,"bytes_processed":4000,"bytes_uploaded":1000,"path":"a","elapsed":2.0}"#)
    #expect(output.progress?.bytesSent == nil)
}
