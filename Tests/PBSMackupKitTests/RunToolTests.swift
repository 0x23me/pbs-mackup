import Foundation
import Testing
@testable import PBSMackupKit

// Starts the real pbs-mackup-run against a stand-in client, in a private home folder
// (`PBS_MACKUP_HOME`), and looks at what it leaves behind. These tests take and mount real APFS
// snapshots, so they only run with PBS_MACKUP_SNAPSHOT_TESTS=1 (`just test-snapshots`) and need
// Full Disk Access for the terminal. They never touch PBS, the Keychain or the real state.

private let token = "TOKEN-SECRET-7f3a", key = "KEY-SECRET-91bc"

/// The stand-in client, compiled for each test: it has to be a real program called
/// `proxmox-backup-client`, because an orphan is only stopped if it is one. PBS_MACKUP_STUB says
/// what it does.
private let stub = #"""
    #include <copyfile.h>
    #include <dirent.h>
    #include <fcntl.h>
    #include <libgen.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <sys/stat.h>
    #include <sys/time.h>
    #include <unistd.h>

    static void touch(const char *home, const char *name) {
        char path[4096];
        snprintf(path, sizeof path, "%s/%s", home, name);
        FILE *file = fopen(path, "w");
        if (file) fclose(file);
    }

    /* Whether the folder has an entry of exactly this name. The client compares names byte by
       byte; the file system also finds a name whose accents are written another way. */
    static int holds(const char *folder, const char *name) {
        DIR *entries = opendir(folder);
        struct dirent *entry;
        int found = 0;
        while (entries && (entry = readdir(entries))) if (!strcmp(entry->d_name, name)) found = 1;
        if (entries) closedir(entries);
        return found;
    }

    int main(int argc, char **argv) {
        const char *home = getenv("PBS_MACKUP_HOME"), *mode = getenv("PBS_MACKUP_STUB");
        char path[4096], buffer[4096];
        ssize_t count;
        while (read(0, buffer, sizeof buffer) > 0) {}        /* the key, on standard input */
        /* The token, on descriptor 3; kept to look at. */
        snprintf(path, sizeof path, "%s/client-token", home);
        int token = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        while ((count = read(3, buffer, sizeof buffer)) > 0) write(token, buffer, count);
        close(token);

        /* catalog extract <snapshot> <archive> <path> <target>: a copy of the source file, with
           all metadata; PBS_MACKUP_STUB_EXTRACT=alter changes its first byte and nothing else. */
        if (argc > 6 && !strcmp(argv[1], "catalog") && !strcmp(argv[2], "extract")) {
            char restored[4096];
            const char *alter = getenv("PBS_MACKUP_STUB_EXTRACT");
            struct stat info;
            /* The path comes with a slash in front (Client.pathArgument), which the client drops. */
            char *item = argv[5];
            while (*item == '/') item++;
            snprintf(path, sizeof path, "%s/Source/%s", home, item);
            snprintf(restored, sizeof restored, "%s/%s", argv[6], basename(item));
            mkdir(argv[6], 0700);
            char folder[4096];
            snprintf(folder, sizeof folder, "%s", path);
            *strrchr(folder, '/') = 0;
            if (!holds(folder, basename(item)) || stat(path, &info) != 0 || copyfile(path, restored, NULL, COPYFILE_ALL) != 0) {
                fprintf(stderr, "Error: no such path in %s: %s\n", argv[4], item);
                return 255;
            }
            if (alter && !strcmp(alter, "alter")) {
                int file = open(restored, O_WRONLY);
                write(file, "X", 1);
                close(file);
                struct timeval times[2] = {{info.st_atimespec.tv_sec, 0}, {info.st_mtimespec.tv_sec, 0}};
                utimes(restored, times);
            }
            return 0;
        }

        snprintf(path, sizeof path, "%s/client-arguments", home);
        FILE *arguments = fopen(path, "w");
        for (int i = 1; i < argc; i++) {
            fprintf(arguments, "%s\n", argv[i]);
            char *source = strstr(argv[i], ".pxar:");
            struct stat info;
            if (source && stat(source + 6, &info) == 0 && S_ISDIR(info.st_mode)) touch(home, "source-visible");
            /* The list of changed folders is gone after the run; keep a copy to look at. */
            if (!strcmp(argv[i], "--changed-dirs") && i + 1 < argc) {
                snprintf(path, sizeof path, "%s/changed-list", home);
                copyfile(argv[i + 1], path, NULL, COPYFILE_DATA);
            }
        }
        fclose(arguments);
        if (mode && !strcmp(mode, "hang")) { touch(home, "client-started"); sleep(300); return 0; }
        /* The last line the client writes, without a newline at its end. */
        if (mode && !strcmp(mode, "fail")) { fprintf(stderr, "Error: the datastore is full"); return 255; }
        /* A backup that lacks a.txt: the snapshot the run reads from still has it, a restore finds nothing. */
        if (mode && !strcmp(mode, "lose")) { snprintf(path, sizeof path, "%s/Source/a.txt", home); unlink(path); }
        fprintf(stderr, "Starting backup: [test]:host/test-mac/2026-01-02T03:04:05Z\n");
        puts("{\"type\":\"progress\",\"entries\":2,\"bytes_processed\":10,\"bytes_uploaded\":4,\"path\":\"a.txt\",\"elapsed\":0.1}");
        puts("{\"type\":\"result\",\"ok\":true,\"snapshot\":\"host/test-mac/2026-01-02T03:04:05Z\",\"namespace\":\"test\",\"entries\":2,\"bytes_processed\":10,\"bytes_reused\":6,\"bytes_uploaded\":4,\"skipped_placeholders\":[],\"skipped_placeholder_count\":0,\"time_machine_excluded\":0,\"warnings\":[],\"duration\":0.1}");
        return 0;
    }
    """#

private final class Fixture {
    let home: URL
    private let listener: Int32
    private var environment: [String: String]

    /// `reachable: false` names a port nothing listens on.
    init(reachable: Bool = true) throws {
        // Under the real temporary folder: it is on the Data volume, so it is in the snapshot.
        home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pbs-mackup-test-\(UUID().uuidString)")
        let source = home.appendingPathComponent("Source"), bin = home.appendingPathComponent("bin")
        for folder in [source, bin] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        // Two files to check after the backup, one with an attribute. An old modification date
        // also moves the creation date back to it, so a faithful copy can match both.
        for name in ["a.txt", "tagged.txt"] {
            let file = source.appendingPathComponent(name)
            try Data("hello \(name)".utf8).write(to: file)
            // Not a quarantine attribute: macOS rewrites that one when the stand-in copies the file.
            if name == "tagged.txt" { setxattr(file.path, "org.example.note", "kept", 4, 0, 0) }
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: file.path)
        }
        let client = bin.appendingPathComponent("proxmox-backup-client")
        let code = home.appendingPathComponent("stub.c")
        try Data(stub.utf8).write(to: code)
        let compiled = tool("/usr/bin/cc", ["-o", client.path, code.path])
        try #require(compiled.status == 0, "\(compiled.output)")

        // A listening socket stands in for the server: a run only checks that it can connect.
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        self.listener = listener
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = bind(listener, $0, length)
                _ = getsockname(listener, $0, &length)
            }
        }
        if reachable { listen(listener, 8) }
        let port = Int(UInt16(bigEndian: address.sin_port))

        environment = ProcessInfo.processInfo.environment
        environment["PBS_MACKUP_HOME"] = home.path
        setenv("PBS_MACKUP_HOME", home.path, 1)     // for Paths and State in this process
        try Config(repository: "test@pbs!mac@127.0.0.1:\(port):store", namespace: "test", backupID: "test-mac",
                   sources: [source.path], excludes: ["*.tmp"], frozenSnapshot: .required, clientPath: client.path).save()
        try Keychain.set(.token, Data(token.utf8))
        try Keychain.set(.encryptionKey, Data(key.utf8))
    }

    deinit {
        close(listener)
        LocalSnapshot.unmount(Paths.mount)
        try? FileManager.default.removeItem(at: home)
    }

    private var runTool: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/pbs-mackup-run")
    }

    /// What the stand-in does when asked to restore a file: nil for a faithful copy, "alter" for a changed one.
    var extract: String?

    func start(_ mode: String, _ arguments: [String] = ["--manual"]) throws -> (process: Process, output: Pipe) {
        let process = Process(), output = Pipe()
        process.executableURL = runTool
        process.arguments = arguments
        environment["PBS_MACKUP_STUB"] = mode
        environment["PBS_MACKUP_STUB_EXTRACT"] = extract
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        return (process, output)
    }

    /// Runs to the end; returns the exit status and what the tool printed.
    func run(_ mode: String, _ arguments: [String] = ["--manual"]) throws -> (status: Int32, output: String) {
        let (process, output) = try start(mode, arguments)
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, text)
    }

    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: home.appendingPathComponent(name).path) }

    func waitFor(_ name: String) throws {
        for _ in 0..<300 where !exists(name) { usleep(100_000) }
        try #require(exists(name), "the client never started")
    }

    var state: State { State.load() }
    var mounted: Bool { LocalSnapshot.isMounted(Paths.mount) }
}

/// The local snapshots Time Machine and anyone else hold right now.
private func localSnapshots() -> Set<String> {
    Set(tool("/usr/bin/tmutil", ["listlocalsnapshots", "/"]).output.split(separator: "\n")
        .filter { $0.hasPrefix("com.apple.TimeMachine.") }.map(String.init))
}

/// Tests that move the app's files with PBS_MACKUP_HOME share that one environment variable, so
/// they run one after another.
@Suite(.serialized)
struct PrivateHomeTests {
@Test func aMeasurementIsKeptInTheCacheForItsFolder() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("pbs-mackup-sizes-\(UUID().uuidString)")
    setenv("PBS_MACKUP_HOME", home.path, 1)
    defer { unsetenv("PBS_MACKUP_HOME"); try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home.appendingPathComponent("data/sub"), withIntermediateDirectories: true)
    try Data(count: 100).write(to: home.appendingPathComponent("data/sub/file"))
    let folder = home.appendingPathComponent("data").path
    #expect(FolderSizes.load(for: folder) == nil)
    let sizes = try FolderSizes.measure(folder, smallest: 0)
    let file = try sizes.save()
    #expect(file.path.hasPrefix(Paths.sizes.path))
    #expect(FolderSizes.load(for: folder)?.root == sizes.root)
    #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
}

@Test func aPaperKeyTypedBackInIsTheKey() throws {
    // PBS_MACKUP_HOME makes the key a file in a private folder instead of a Keychain item.
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("pbs-mackup-key-\(UUID().uuidString)")
    setenv("PBS_MACKUP_HOME", home.path, 1)
    defer { unsetenv("PBS_MACKUP_HOME"); try? FileManager.default.removeItem(at: home) }
    let key = Data(#"{"kdf":null,"created":"2026-01-02T03:04:05+01:00","data":"bm90IGEgcmVhbCBrZXk=","fingerprint":"aa:bb:cc"}"#.utf8)
    #expect(try KeyStore.status().present == false)
    #expect(throws: KeyStore.Failure.self) { try KeyStore.importKey(Data("not a key".utf8)) }
    #expect(try KeyStore.importKey(key).fingerprint == "aa:bb:cc")

    let paper = try KeyStore.paperKey(subject: "test-mac")
    #expect(paper.contains("Fingerprint: aa:bb:cc"))
    try Keychain.set(.encryptionKey, Data())                       // lose the key,
    #expect(try KeyStore.status().present == false)
    #expect(try KeyStore.importKey(Data(paper.utf8)).fingerprint == "aa:bb:cc")   // and get it back from the page
    #expect(try Keychain.get(.encryptionKey) == key)

    let copy = home.appendingPathComponent("recovery.json")
    try KeyStore.export(to: copy)
    #expect(try Data(contentsOf: copy) == key)
    #expect(try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? Int == 0o600)
}

@Test func anExistingItemIsOnlyReplacedWhenAskedTo() throws {
    let fixture = try Fixture()                     // its stand-in client restores copies of the fixture's Source folder
    let client = try Client(config: Config.load())
    let folder = fixture.home.appendingPathComponent("Restored")
    func restore(_ conflict: Client.Conflict) throws -> String? {
        try client.restore(snapshot: "host/test-mac/2026-01-02T03:04:05Z", archive: "Source.pxar", path: "a.txt",
                           into: folder, conflict: conflict)?.lastPathComponent
    }
    func contents(_ name: String) -> String? { try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) }

    #expect(try restore(.skip) == "a.txt")          // nothing there yet: every choice just restores
    #expect(contents("a.txt") == "hello a.txt")
    try Data("my newer text".utf8).write(to: folder.appendingPathComponent("a.txt"))

    #expect(try restore(.skip) == nil)
    #expect(contents("a.txt") == "my newer text")
    #expect(try restore(.keepBoth) == "a 2.txt")
    #expect(contents("a.txt") == "my newer text")
    #expect(contents("a 2.txt") == "hello a.txt")
    #expect(try restore(.replace) == "a.txt")
    #expect(contents("a.txt") == "hello a.txt")
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["a 2.txt", "a.txt"])   // no staging folder left
}

@Test func aRunningClientShowsItsSecretsToNoOtherProgram() throws {
    let fixture = try Fixture()
    setenv("PBS_MACKUP_STUB", "hang", 1)            // the stand-in stays, as a client does while it backs up
    defer { unsetenv("PBS_MACKUP_STUB") }
    let client = try Client(config: Config.load()).start(["backup"], mergingErrors: true)
    defer { client.signal(SIGKILL); client.wait() }
    try fixture.waitFor("client-started")
    // What every program of the user can read of another: its arguments and its environment.
    let shown = tool("/bin/ps", ["-E", "-ww", "-o", "command=", "-p", "\(client.pid)"]).output
    try #require(shown.contains("PBS_PASSWORD_FD=3"), "ps did not show the environment: \(shown)")
    #expect(!shown.contains(token) && !shown.contains(key))
    // The token went over descriptor 3, as one line.
    #expect(try String(contentsOf: fixture.home.appendingPathComponent("client-token"), encoding: .utf8) == token + "\n")
    // And the client ends when it is interrupted, which is how a run is cancelled.
    client.interrupt()
    #expect(client.wait() == SIGINT)
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["PBS_MACKUP_SNAPSHOT_TESTS"] == "1"))
struct RunToolTests {
    @Test func aRunReadsFromItsSnapshotAndLeavesNothingBehind() throws {
        let before = localSnapshots()
        let fixture = try Fixture()
        // A file and a rule with ü in one piece, as git, unzip or a browser write it. Made
        // with open, which keeps the name as it is given; Foundation would take the accent apart.
        let named = "Z\u{FC}rich.txt", rule = "B\u{FC}cher"
        let file = open(fixture.home.path + "/Source/" + named, O_CREAT | O_WRONLY, 0o600)
        #expect(file >= 0 && write(file, "hello", 5) == 5 && close(file) == 0)
        var times = [timeval(tv_sec: 1_600_000_000, tv_usec: 0), timeval(tv_sec: 1_600_000_000, tv_usec: 0)]
        #expect(utimes(fixture.home.path + "/Source/" + named, &times) == 0)
        var config = try Config.load()
        config.excludes += [rule, "-dash"]
        try config.save()

        let result = try fixture.run("ok")
        #expect(result.status == 0, "\(result.output)")
        let record = try #require(fixture.state.last)
        #expect(record.outcome == .success)
        #expect(record.frozen)
        #expect(record.snapshot == "host/test-mac/2026-01-02T03:04:05Z")
        #expect(record.result.entries == 2)
        #expect(record.result.bytesUploaded == 4)
        // All three files were restored and compared. The stand-in, like the client, only finds
        // a name that reaches it byte for byte.
        #expect(record.checkedFiles == 3)
        #expect(record.mismatches == nil)
        #expect(fixture.exists("source-visible"))        // the client was pointed at an existing folder inside the mount
        let noted = try Data(contentsOf: fixture.home.appendingPathComponent("client-arguments"))
        let arguments = String(decoding: noted, as: UTF8.self)
        #expect(arguments.contains("Source.pxar:\(Paths.mount.path)/"))
        // The default exclusions and the owner's own, encryption, change detection, a stable group.
        // Each exclusion in one piece with its option, so that one with a dash in front is no option.
        for expected in ["--exclude=.DS_Store\n", "--exclude=/Library/Caches\n", "--exclude=*.tmp\n", "--exclude=-dash\n", "--crypt-mode\nencrypt\n",
                         "--change-detection-mode=metadata\n", "--backup-id\ntest-mac\n", "--ns\ntest\n", "--skip-tm-excluded\ntrue\n"] {
            #expect(arguments.contains(expected), "missing \(expected)")
        }
        #expect(noted.range(of: Data("--exclude=\(rule)\n".utf8)) != nil)     // the rule's own bytes
        #expect(!fixture.mounted)
        #expect(fixture.state.localSnapshot == nil)
        #expect(fixture.state.running == nil)
        #expect(localSnapshots() == before)               // its own snapshot is gone, Time Machine's are all there

        // No secret in the client's arguments or in the log; the token came over descriptor 3.
        let log = try String(contentsOfFile: try #require(record.log), encoding: .utf8)
        for secret in [token, key] {
            #expect(!arguments.contains(secret))
            #expect(!log.contains(secret))
        }
        #expect(try String(contentsOf: fixture.home.appendingPathComponent("client-token"), encoding: .utf8) == token + "\n")
    }

    @Test func aLaterRunHandsTheClientOnlyWhatChanged() throws {
        let fixture = try Fixture()
        func arguments() throws -> String {
            try String(contentsOf: fixture.home.appendingPathComponent("client-arguments"), encoding: .utf8)
        }
        var result = try fixture.run("ok")
        #expect(result.status == 0, "\(result.output)")
        #expect(try !arguments().contains("--changed-dirs"))
        #expect(fixture.state.last?.changes == "everything read: no earlier backup to build on")
        #expect(fixture.state.changeBase?.snapshot == "host/test-mac/2026-01-02T03:04:05Z")

        // One file edited, one folder made.
        let source = fixture.home.appendingPathComponent("Source")
        let real = try #require(realpath(source.path, nil).map { pointer -> String in defer { free(pointer) }; return String(cString: pointer) })
        try Data("changed".utf8).write(to: source.appendingPathComponent("a.txt"))
        try FileManager.default.createDirectory(at: source.appendingPathComponent("new folder"), withIntermediateDirectories: false)
        try Data("new".utf8).write(to: source.appendingPathComponent("new folder/b.txt"))
        // As in the fixture: an old modification date, so the stand-in's copy can match the creation date.
        for name in ["a.txt", "new folder/b.txt"] {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
                                                  ofItemAtPath: source.appendingPathComponent(name).path)
        }
        result = try fixture.run("ok")
        #expect(result.status == 0, "\(result.output)")
        #expect(try arguments().contains("--changed-dirs\n\(Paths.changedFolders.path)\n--changed-dirs-base\n2026-01-02T03:04:05Z\n"))
        let list = try String(contentsOf: fixture.home.appendingPathComponent("changed-list"), encoding: .utf8)
        #expect(list.split(separator: "\0").map(String.init)
                == ["r\(Paths.mount.path)\(real)/new folder", "d\(Paths.mount.path)\(real)"])
        #expect(fixture.state.last?.changes == "2 changed folders read, the rest taken over from host/test-mac/2026-01-02T03:04:05Z")
        #expect(!fixture.exists("cache/changed-folders"))

        // Other exclusions: what was taken over could be wrong, so everything is read.
        var config = try Config.load()
        config.excludes.append("*.bak")
        try config.save()
        result = try fixture.run("ok")
        #expect(try !arguments().contains("--changed-dirs"))
        #expect(fixture.state.last?.changes == "everything read: folders, exclusions or the client changed")
        result = try fixture.run("ok", ["--full"])
        #expect(try !arguments().contains("--changed-dirs"))
        #expect(fixture.state.last?.changes == "everything read: asked to")
        // Nothing changed since: an empty list, and the client is told so.
        result = try fixture.run("ok")
        #expect(try arguments().contains("--changed-dirs\n"))
        #expect(fixture.state.last?.changes == "0 changed folders read, the rest taken over from host/test-mac/2026-01-02T03:04:05Z")
    }

    @Test func theNextRunCleansUpAfterAKilledOne() throws {
        let before = localSnapshots()
        let fixture = try Fixture()
        let (first, _) = try fixture.start("hang")
        try fixture.waitFor("client-started")
        let client = try #require(fixture.state.running?.clientPID)
        kill(first.processIdentifier, SIGKILL)
        first.waitUntilExit()
        #expect(fixture.mounted)                          // the killed run left its mount,
        #expect(localSnapshots().count == before.count + 1)   // its snapshot,
        #expect(kill(client, 0) == 0)                     // and its client

        let result = try fixture.run("ok")
        #expect(result.status == 0, "\(result.output)")
        #expect(fixture.state.last?.outcome == .success)
        #expect(!fixture.mounted)
        #expect(localSnapshots() == before)
        #expect(kill(client, 0) != 0)
    }

    @Test func aSecondStartDoesNotRunAndCancellingCleansUp() throws {
        let before = localSnapshots()
        let fixture = try Fixture()
        let (first, _) = try fixture.start("hang")
        try fixture.waitFor("client-started")

        let second = try fixture.run("ok")
        #expect(second.status == Runner.Exit.alreadyRunning.rawValue)
        #expect(second.output.contains("already running"))
        #expect(fixture.state.running?.pid == first.processIdentifier)   // the first run is untouched

        let cancelled = Date()
        kill(first.processIdentifier, SIGTERM)
        first.waitUntilExit()
        #expect(Date().timeIntervalSince(cancelled) < 10)
        #expect(fixture.state.last?.outcome == .cancelled)
        #expect(fixture.state.last?.snapshot == nil)
        #expect(!fixture.mounted)
        #expect(localSnapshots() == before)
    }

    @Test func anUnreachableServerIsASkipNotAFailure() throws {
        let before = localSnapshots()
        let fixture = try Fixture(reachable: false)
        let result = try fixture.run("ok", [])            // a scheduled run
        #expect(result.status == 0)
        let record = try #require(fixture.state.last)
        #expect(record.outcome == .skipped)
        #expect(record.trigger == .scheduled)
        #expect(record.reason?.contains("not reachable") == true)
        #expect(fixture.state.consecutiveFailures == 0)
        #expect(!fixture.exists("client-arguments"))      // nothing was started,
        #expect(localSnapshots() == before)               // and no snapshot was taken
    }

    @Test func aRestoredSampleThatDiffersFailsTheRunAndNamesTheFile() throws {
        let before = localSnapshots()
        let fixture = try Fixture()
        fixture.extract = "alter"
        let result = try fixture.run("ok")
        #expect(result.status == Runner.Exit.failed.rawValue)
        let record = try #require(fixture.state.last)
        #expect(record.outcome == .failed)
        #expect(record.step == .verify)
        #expect(record.checkedFiles == 2)
        #expect(record.mismatches?.sorted() == ["a.txt (contents)", "tagged.txt (contents)"])
        #expect(record.reason?.contains("a.txt (contents)") == true)
        #expect(record.snapshot == "host/test-mac/2026-01-02T03:04:05Z")   // the snapshot exists; the record says which
        #expect(fixture.state.changeBase == nil)          // but the next run takes nothing over from it
        #expect(fixture.state.consecutiveFailures == 1)
        #expect(fixture.state.lastSuccess == nil)
        #expect(!fixture.mounted)
        #expect(localSnapshots() == before)
    }

    @Test func aFileTheBackupLostFailsTheRunWhateverTheOwnerLeavesOut() throws {
        let fixture = try Fixture()                       // the owner leaves out *.tmp, which a.txt is not
        var result = try fixture.run("ok")
        #expect(result.status == 0, "\(result.output)")
        #expect(fixture.state.changeBase != nil)
        result = try fixture.run("lose")
        #expect(result.status == Runner.Exit.failed.rawValue)
        let record = try #require(fixture.state.last)
        #expect(record.outcome == .failed)
        #expect(record.step == .verify)
        #expect(record.checkedFiles == 2)
        #expect(record.mismatches == ["a.txt (cannot be restored: no such path in Source.pxar: a.txt)"])
        #expect(fixture.state.changeBase == nil)          // the earlier basis is gone too: the next run reads everything
    }

    @Test func aMissingFileIsForgivenUnderARuleTheCheckCannotJudge() throws {
        let fixture = try Fixture()
        var config = try Config.load()
        config.excludes = ["**/drafts"]                   // may well leave out a.txt, as far as the check can tell
        try config.save()
        let result = try fixture.run("lose")
        #expect(result.status == 0, "\(result.output)")
        let record = try #require(fixture.state.last)
        #expect(record.outcome == .success)
        #expect(record.checkedFiles == 1)
        #expect(record.mismatches == nil)
    }

    @Test func aFailingClientIsRecordedWithItsError() throws {
        let before = localSnapshots()
        let fixture = try Fixture()
        let result = try fixture.run("fail")
        #expect(result.status == Runner.Exit.failed.rawValue)
        let record = try #require(fixture.state.last)
        #expect(record.outcome == .failed)
        #expect(record.step == .backup)
        #expect(record.reason == "the datastore is full")
        #expect(fixture.state.consecutiveFailures == 1)
        #expect(fixture.state.lastSuccess == nil)
        let log = try String(contentsOfFile: try #require(record.log), encoding: .utf8)
        #expect(log.contains("Error: the datastore is full"))
        #expect(!fixture.mounted)
        #expect(localSnapshots() == before)
    }
}
}
