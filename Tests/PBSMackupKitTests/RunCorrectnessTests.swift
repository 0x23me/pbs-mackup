import Foundation
import Testing
@testable import PBSMackupKit

// When a run is due, what it takes for the next one to build on, what the sample check picks
// and forgives, whether a recorded run is still going, and the pause.

private func record(_ outcome: Outcome, at start: Date, took seconds: Double = 60, trigger: Trigger = .scheduled,
                    reason: String? = nil) -> RunRecord {
    RunRecord(start: start, end: start.addingTimeInterval(seconds), trigger: trigger, outcome: outcome, reason: reason,
              step: nil, snapshot: nil, frozen: true, result: BackupResult(), log: nil)
}

private func minutes(_ count: Double) -> TimeInterval { count * 60 }

// MARK: - When the next run is due

@Test func theIntervalCountsFromTheLastBackupNotFromTheLastTry() {
    let day = 24 * 60, start = Date(timeIntervalSince1970: 1_800_000_000)
    var state = State()
    #expect(state.nextRun(intervalMinutes: day) == .distantPast)           // nothing yet: now
    state.finish(record(.success, at: start))
    #expect(state.nextRun(intervalMinutes: day) == start.addingTimeInterval(minutes(Double(day))))

    // A day later the server is not reachable. Counted from that try, the next would be another day away.
    let turn = start.addingTimeInterval(minutes(Double(day)))
    state.finish(record(.skipped, at: turn, took: 5, reason: "The server pbs is not reachable."))
    #expect(state.nextRun(intervalMinutes: day) == turn)
    #expect(Runner.isDue(state, intervalMinutes: day, now: turn.addingTimeInterval(minutes(5))))     // the next tick tries again

    // A run by hand that could not start does not bring the next scheduled one forward.
    state.finish(record(.success, at: turn.addingTimeInterval(minutes(10))))
    state.finish(record(.skipped, at: turn.addingTimeInterval(minutes(20)), took: 5, trigger: .manual))
    #expect(!Runner.isDue(state, intervalMinutes: day, now: turn.addingTimeInterval(minutes(25))))
}

@Test func aFailedRunIsTriedAgainSoonAndThenLessAndLessOften() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func waits(intervalMinutes: Int, failures: Int) -> [Double] {
        var state = State(), waits: [Double] = []
        state.finish(record(.success, at: start.addingTimeInterval(-minutes(Double(intervalMinutes)))))
        for _ in 0..<failures {
            let failed = record(.failed, at: start, took: 120)
            state.finish(failed)
            waits.append(state.nextRun(intervalMinutes: intervalMinutes).timeIntervalSince(failed.end) / 60)
        }
        return waits
    }
    // A quarter of an hour after it ended, then twice as long each time, never more than the interval.
    #expect(waits(intervalMinutes: 24 * 60, failures: 9) == [15, 30, 60, 120, 240, 480, 960, 1440, 1440])
    #expect(waits(intervalMinutes: 60, failures: 4) == [15, 30, 60, 60])
    #expect(waits(intervalMinutes: 5, failures: 2) == [5, 5])

    // A failure never brings the next run forward: a run by hand failed ten minutes after a backup.
    var state = State()
    state.finish(record(.success, at: start))
    state.finish(record(.failed, at: start.addingTimeInterval(minutes(10)), trigger: .manual))
    #expect(state.nextRun(intervalMinutes: 60) == start.addingTimeInterval(minutes(60)))
    // And a skip after a failure is tried again at once, as any skip is.
    state.finish(record(.skipped, at: start.addingTimeInterval(minutes(60))))
    #expect(Runner.isDue(state, intervalMinutes: 60, now: start.addingTimeInterval(minutes(65))))
}

@Test func aCancelledRunIsFollowedByAWholeInterval() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var state = State()
    state.finish(record(.success, at: start))
    let cancelled = start.addingTimeInterval(minutes(60))
    state.finish(record(.cancelled, at: cancelled))
    #expect(!Runner.isDue(state, intervalMinutes: 60, now: cancelled.addingTimeInterval(minutes(5))))
    #expect(state.nextRun(intervalMinutes: 60) == cancelled.addingTimeInterval(minutes(60)))
}

/// launchd's five-minute ticks over a stretch of time in which every run that is due fails.
private func failing(intervalMinutes: Int, forMinutes span: Int) -> (runs: [Int], notice: Int?) {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var state = State(), notices = Notices(), runs: [Int] = [], notice: Int?
    state.finish(record(.success, at: start.addingTimeInterval(-minutes(Double(intervalMinutes)))))
    for tick in stride(from: 0, through: span, by: 5) {
        let now = start.addingTimeInterval(minutes(Double(tick)))
        if Runner.isDue(state, intervalMinutes: intervalMinutes, now: now) {
            state.finish(record(.failed, at: now, reason: "The datastore is full."))
            runs.append(tick)
        }
        if notices.check(state, now: now.addingTimeInterval(61)) != nil, notice == nil { notice = tick }
    }
    return (runs, notice)
}

@Test func threeFailuresInARowAreMostOfAnHourOfFailing() {
    // With a backup a day the second try used to come a day later and the notice after two.
    let daily = failing(intervalMinutes: 24 * 60, forMinutes: 24 * 60)
    #expect(daily.runs == [0, 20, 55, 120, 245, 490, 975])       // seven tries in a day, not one and not 96
    #expect(daily.notice == 55)
    let hourly = failing(intervalMinutes: 60, forMinutes: 240)
    #expect(hourly.runs == [0, 20, 55, 120, 185])
    #expect(hourly.notice == 55)
}

// MARK: - Whether a recorded run is still going

@Test func aRecordedRunIsOnlyLiveWhileItsOwnProcessIs() throws {
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleeper.arguments = ["30"]
    try sleeper.run()
    defer { sleeper.terminate() }
    let pid = sleeper.processIdentifier
    #expect(Running.isProcess(pid, program: "sleep", startedBy: Date()))
    #expect(!Running.isProcess(pid, program: "pbs-mackup-run", startedBy: Date()))                    // there, but another program
    #expect(!Running.isProcess(pid, program: "sleep", startedBy: Date().addingTimeInterval(-3600)))   // younger than the run: it took the id over
    sleeper.terminate()
    sleeper.waitUntilExit()
    #expect(!Running.isProcess(pid, program: "sleep", startedBy: Date()))

    // What the app asked before, whether any process has that id, is true of this very test.
    let mine = Running(pid: getpid(), start: Date(), trigger: .manual, progress: Progress(step: .preparing, updated: Date()))
    #expect(kill(mine.pid, 0) == 0)
    #expect(!mine.isLive)
}

// MARK: - The sample check

@Test func theSampleLeavesOutWhatTheOwnersRulesLeaveOut() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pbs-mackup-rules-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let files = ["keep.txt", "big.iso", "code/app/main.swift", "code/app/node_modules/lib/index.js", "Movies/Raw/clip.mov",
                 "Movies/cut.mov", ".pxarexclude-cli", "-rf"]
    for file in files {
        let url = root.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }
    func seen(_ rules: [String]) -> Set<String> {
        var seen = Set<String>()
        for _ in 0..<10 { seen.formUnion(SampleCheck.pick(in: root, count: 10, maxBytes: 1000, excludes: rules)) }
        return seen
    }
    // Without the rules, which is what the picker knew before: files no backup made with them has.
    // Never among them: the client's own list of rules at the top. A file whose name begins
    // with a dash is: it is asked for with a slash in front, which makes it a path.
    #expect(seen([]) == Set(files).subtracting([".pxarexclude-cli"]))
    // A name anywhere, a pattern, and a path from the top, which also covers what is below it.
    #expect(seen(["*.iso", "node_modules", "/Movies/Raw"]) == ["keep.txt", "code/app/main.swift", "Movies/cut.mov", "-rf"])
    #expect(SampleCheck.pick(in: root.appendingPathComponent("not there"), count: 10, maxBytes: 1000).isEmpty)
}

@Test func theSampleTakesNamesAndRulesAsTheyAreWritten() throws {
    // An accent in one piece with its letter (ü), and as a character of its own after it (u, ¨).
    // A folder keeps a name as it was made, and the client compares names and rules byte by byte.
    let whole = "\u{FC}", apart = "u\u{308}"
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pbs-mackup-names-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    // Made with mkdir and open, which keep a name as it is given; Foundation would take the accents apart.
    let folders = ["Z\(whole)rich one", "Z\(apart)rich two", "\(apart)bung", "B\(whole)cher"]
    #expect(mkdir(root.path, 0o700) == 0)
    for folder in folders {
        #expect(mkdir(root.path + "/" + folder, 0o700) == 0)
        let file = open(root.path + "/" + folder + "/file.txt", O_CREAT | O_WRONLY, 0o600)
        #expect(file >= 0)
        close(file)
    }
    func seen(_ rules: [String]) -> Set<[UInt8]> {
        var seen = Set<[UInt8]>()
        for _ in 0..<10 { seen.formUnion(SampleCheck.pick(in: root, count: 10, maxBytes: 1000, excludes: rules).map { Array($0.utf8) }) }
        return seen
    }
    func files(_ folders: [String]) -> Set<[UInt8]> { Set(folders.map { Array("\($0)/file.txt".utf8) }) }
    // Written either way a file is picked, under the name the folder has for it.
    #expect(seen([]) == files(folders))
    // A rule leaves out the name that is written as the rule is, and not the other.
    #expect(seen(["\(whole)bung", "B\(whole)cher"]) == files(["Z\(whole)rich one", "Z\(apart)rich two", "\(apart)bung"]))
}

@Test func theSampleCheckOnlyGoesByRulesItJudgesAsTheClientDoes() {
    for rule in ["node_modules", "*.iso", "/Movies/Raw", "/code/*/target", "app/build", "build/", "file-??.txt", "!keep/**",
                 LeaveOut.rule(forPath: "code/what? [old]*")] {
        #expect(SampleCheck.canJudge(rule), "\(rule)")
    }
    for rule in ["**/cache", "/code/**", "[!ab].txt", "./build", "a//b", "code/../build"] {
        #expect(!SampleCheck.canJudge(rule), "\(rule)")
    }
    // Why not those: the client lets `/**/` stand for a single slash, takes `!` in a class as
    // a character like any other, and reads `./build` as `build`.
    #expect(!LeaveOut.matches("/a/**/b", relative: "a/b"))
    #expect(!LeaveOut.matches("[!ab].txt", relative: "a.txt"))
    #expect(!LeaveOut.matches("./build", relative: "build"))
    // A question mark is one byte, here as in the client.
    #expect(LeaveOut.matches("file-??.txt", relative: "file-é.txt"))
}

@Test func aFileMissingFromTheBackupIsOnlyForgivenWhereItMayRightlyBeMissing() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("pbs-mackup-absent-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("root")
    for file in ["root/a/b/file.txt", "root/other.txt", "elsewhere/moved/old.txt"] {
        let url = base.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }
    usleep(50_000)
    let start = Date()          // the run begins,
    usleep(50_000)
    // and while it reads the live folders, a folder with an old file in it is moved in.
    try FileManager.default.moveItem(at: base.appendingPathComponent("elsewhere/moved"), to: root.appendingPathComponent("a/moved"))
    #expect(SampleCheck.mayBeAbsent("a/moved/old.txt", in: root, liveSince: start))
    #expect(!SampleCheck.mayBeAbsent("a/b/file.txt", in: root, liveSince: start))     // was there all along, next to it
    #expect(!SampleCheck.mayBeAbsent("other.txt", in: root, liveSince: start))
    #expect(SampleCheck.mayBeAbsent("a/gone.txt", in: root, liveSince: start))        // there when picked, deleted since
    // From a frozen snapshot nothing can have come later.
    #expect(!SampleCheck.mayBeAbsent("a/moved/old.txt", in: root, liveSince: nil))

    // A folder with rules of its own, which the client obeys and the picker does not read.
    try Data("*.txt\n".utf8).write(to: root.appendingPathComponent("a/.pxarexclude"))
    #expect(SampleCheck.mayBeAbsent("a/b/file.txt", in: root, liveSince: nil))
    #expect(!SampleCheck.mayBeAbsent("other.txt", in: root, liveSince: nil))
}

// MARK: - The pause, and runs that end before a snapshot is taken

/// A configuration whose server cannot be reached, so that a run ends as skipped before it takes
/// a snapshot or starts a client: nothing connects to port 0, and the attempt fails at once.
private func unreachable(home: URL) -> Config {
    Config(repository: "test@pbs!mac@127.0.0.1:0:store", namespace: "test", backupID: "test-mac",
           sources: [home.appendingPathComponent("Source").path], frozenSnapshot: .required)
}

extension PrivateHomeTests {
    @Test func thePauseIsAFileOfItsOwnAndStopsScheduledRuns() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pbs-mackup-pause-\(UUID().uuidString)")
        setenv("PBS_MACKUP_HOME", home.path, 1)
        defer { unsetenv("PBS_MACKUP_HOME"); try? FileManager.default.removeItem(at: home) }
        let config = unreachable(home: home)

        #expect(!Pause.isOn)
        try Pause.set(true)                             // the app, also before there is a support folder
        try Seal.set(config: config)                    // a run only goes by settings the app stored
        #expect(Pause.isOn)
        #expect(Paths.paused.path.hasPrefix(Paths.support.path))
        // The run tool writes its state as often as it likes: the pause is not in it.
        var state = State()
        state.finish(record(.success, at: Date().addingTimeInterval(-7200)))
        try state.save()
        state = State.load()
        #expect(Pause.isOn)

        // A backup is due, but not while paused: the scheduled run does nothing at all.
        #expect(Runner(config: config, trigger: .scheduled).run() == .done)
        #expect(State.load() == state)
        // One started by hand still runs, as far as it gets here.
        #expect(Runner(config: config, trigger: .manual).run() == .done)
        #expect(State.load().last?.outcome == .skipped)
        #expect(State.load().last?.trigger == .manual)
        #expect(Pause.isOn)                             // and leaves the pause as it is

        try Pause.set(false)
        try Pause.set(false)                            // nothing to remove is not an error
        #expect(!Pause.isOn)
    }

    @Test func aPauseKeptInTheStateFileMovesToItsOwnFile() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pbs-mackup-pause-\(UUID().uuidString)")
        setenv("PBS_MACKUP_HOME", home.path, 1)
        defer { unsetenv("PBS_MACKUP_HOME"); try? FileManager.default.removeItem(at: home) }
        let config = unreachable(home: home)
        try Seal.set(config: config)

        // As an earlier version left it: paused, in the state file.
        var old = State()
        old.finish(record(.success, at: Date().addingTimeInterval(-7200)))
        old.paused = true
        try old.save()
        #expect(String(decoding: try Data(contentsOf: Paths.state), as: UTF8.self).contains(#""paused" : true"#))
        old = State.load()
        #expect(!Pause.isOn)

        #expect(Runner(config: config, trigger: .scheduled).run() == .done)
        #expect(Pause.isOn)                             // still paused, now by the file,
        #expect(State.load().paused == false)           // and no longer by the field,
        #expect(State.load().last == old.last)          // and the run that was due did not happen
        // so that resuming is not undone by the next run.
        try Pause.set(false)
        #expect(Runner(config: config, trigger: .scheduled).run() == .done)
        #expect(!Pause.isOn)
        #expect(State.load().last?.outcome == .skipped)
    }

    @Test func aRowOfSkipsIsOneRecordAndEveryTickTriesAgain() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pbs-mackup-skips-\(UUID().uuidString)")
        setenv("PBS_MACKUP_HOME", home.path, 1)
        defer { unsetenv("PBS_MACKUP_HOME"); try? FileManager.default.removeItem(at: home) }
        var config = unreachable(home: home)
        config.intervalMinutes = 24 * 60
        try Seal.set(config: config)
        func fileNumber() throws -> Int? {
            try FileManager.default.attributesOfItem(atPath: Paths.state.path)[.systemFileNumber] as? Int
        }

        #expect(Runner(config: config, trigger: .scheduled).run() == .done)
        var state = State.load()
        #expect(state.last?.outcome == .skipped)
        #expect(state.last?.reason == "The server 127.0.0.1 is not reachable.")
        #expect(state.history.count == 1)
        #expect(state.consecutiveFailures == 0)
        // Not a day from now: the next tick tries again,
        #expect(Runner.isDue(state, intervalMinutes: config.interval, now: Date()))
        // and when the reason is the same, it leaves the record and the file as they are.
        let written = try fileNumber()
        for _ in 0..<3 { #expect(Runner(config: config, trigger: .scheduled).run() == .done) }
        #expect(State.load() == state)
        #expect(try fileNumber() == written)

        // A run started by hand always leaves its record.
        #expect(Runner(config: config, trigger: .manual).run() == .done)
        state = State.load()
        #expect(state.history.map(\.trigger) == [.scheduled, .manual])
        #expect(try fileNumber() != written)
    }

    /// A name reaches the client as it was given, byte for byte: from the app to the run tool,
    /// and from the run tool to the client. Foundation's `Process` handed an accent in one piece
    /// with its letter (as git, unzip or a browser write it) over as a letter and an accent
    /// after it, and the client, which compares bytes, answered that there is no such path.
    @Test func aNameReachesTheClientAsItWasGiven() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pbs-mackup-arguments-\(UUID().uuidString)")
        setenv("PBS_MACKUP_HOME", home.path, 1)
        defer { unsetenv("PBS_MACKUP_HOME"); try? FileManager.default.removeItem(at: home) }
        try Keychain.set(.token, Data("token".utf8))
        try Keychain.set(.encryptionKey, Data("key".utf8))
        // A stand-in client that takes the key from standard input. It knows of one snapshot;
        // asked for something in it, it notes its arguments as they are, one to a line, and
        // has nothing.
        let standIn = home.appendingPathComponent("client"), noted = home.appendingPathComponent("arguments")
        try Data(#"""
            #!/bin/sh
            cat > /dev/null
            case "$1" in
                snapshot) echo '[{"backup-type":"host","backup-id":"test-mac","backup-time":1,"files":[{"filename":"Downloads.pxar.didx"}]}]' ;;
                *) printf '%s\n' "$@" > "$PBS_MACKUP_HOME/arguments"; echo '[]' ;;
            esac
            """#.utf8).write(to: standIn)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: standIn.path)
        let config = Config(repository: "test@pbs!mac@127.0.0.1:0:store", namespace: "test", backupID: "test-mac",
                            sources: [], clientPath: standIn.path)
        try config.save()
        func arrived() throws -> [[UInt8]] { try Data(contentsOf: noted).split(separator: 0x0A).map { Array($0) } }

        // Zürich and Bücher with ü in one piece. Swift calls the two ways of writing equal; their bytes are not.
        let path = "Z\u{FC}rich/B\u{FC}cher", given = Array("/\(path)".utf8)
        #expect(Array(path.utf8) != Array(path.decomposedStringWithCanonicalMapping.utf8))
        let snapshot = "host/test-mac/1970-01-01T00:00:01Z"

        // From the run tool to the client: a folder to list, an item to restore, and the
        // folder of an item whose versions are asked for.
        let client = try Client(config: config)
        #expect(try client.list(snapshot: snapshot, archive: "Downloads.pxar", path: path).isEmpty)
        #expect(try arrived().contains(given))
        try FileManager.default.removeItem(at: noted)
        #expect(throws: Client.Failure.self) { try client.restore(snapshot: snapshot, archive: "Downloads.pxar", path: path, into: home) }
        #expect(try arrived().contains(given))
        try FileManager.default.removeItem(at: noted)
        #expect(try client.versions(archive: "Downloads.pxar", path: path + "/x").isEmpty)
        #expect(try arrived().contains(given))

        // From the app to the run tool and on to the client, started the way `RunTool.call` in
        // the app starts it. Only ever the debug build, which keeps to PBS_MACKUP_HOME.
        let tool = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/pbs-mackup-run")
        let environment = ProcessInfo.processInfo.environment.merging(["PBS_MACKUP_HOME": home.path]) { $1 }
        for command in [["list", snapshot, "Downloads.pxar", path], ["versions", "Downloads.pxar", path + "/x"]] {
            try FileManager.default.removeItem(at: noted)
            let result = try Child(tool, command, environment: environment).finish()
            #expect(result.status == 0, "\(String(decoding: result.errors, as: UTF8.self))")
            #expect(try arrived().contains(given), "\(command)")
        }
    }
}
