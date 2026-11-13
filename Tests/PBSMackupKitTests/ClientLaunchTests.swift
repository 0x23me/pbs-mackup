import Foundation
import Security
import Testing
@testable import PBSMackupKit

// How the client is started: which program, with which environment, arguments and input, and
// what is stored before the server said yes. A script stands in for the client and the server.

/// Notes what it was started as and with, the key from standard input and the token from
/// descriptor 3, and answers like a server that knows the tokens that begin with `right`: with
/// `client-answer` when there is one, with no snapshots otherwise.
private let script = #"""
    #!/bin/sh
    home="$PBS_MACKUP_HOME"
    echo "$0" > "$home/client-program"
    env > "$home/client-environment"
    printf '%s\n' "$@" > "$home/client-arguments"
    cat > "$home/client-input"
    cat <&3 > "$home/client-token"
    case "$(cat "$home/client-token")" in
        right*) ;;
        *) echo "Error: permission check failed" >&2; exit 255 ;;
    esac
    cat "$home/client-answer" 2>/dev/null || echo "[]"
    """#

private let snapshot = "host/test-mac/2026-11-12T14:00:05Z"

/// A private home (`PBS_MACKUP_HOME`) whose configuration names the stand-in client.
private struct Home {
    let folder: URL
    let config: Config

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("pbs-mackup-launch-\(UUID().uuidString)")
        let client = folder.appendingPathComponent("bin/proxmox-backup-client")
        try FileManager.default.createDirectory(at: client.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: client)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: client.path)
        setenv("PBS_MACKUP_HOME", folder.path, 1)
        // Nothing listens on port 1, should the real client ever be asked.
        config = Config(repository: "test@pbs!mac@127.0.0.1:1:store", namespace: "test", backupID: "test-mac",
                        sources: [], clientPath: client.path)
    }

    func remove() {
        unsetenv("PBS_MACKUP_HOME")
        try? FileManager.default.removeItem(at: folder)
    }

    /// What the stand-in noted the last time it ran: `program`, `environment`, `arguments`, `input` or `token`.
    func noted(_ what: String) -> String? {
        try? String(contentsOf: folder.appendingPathComponent("client-\(what)"), encoding: .utf8)
    }

    var environment: [String: String] {
        var environment: [String: String] = [:]
        for line in (noted("environment") ?? "").split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { environment[String(parts[0])] = String(parts[1]) }
        }
        return environment
    }

    func answer(_ text: String) throws {
        try Data(text.utf8).write(to: folder.appendingPathComponent("client-answer"))
    }
}

private func failure(_ work: () throws -> Void) -> String? {
    do { try work(); return nil } catch { return "\(error)" }
}

@Test func onlyNamesPassAsSnapshotsAndArchives() {
    for name in [snapshot, "host/My_Mac.local-2/2026-11-12T14:00:05Z", "host/_/1970-01-01T00:00:00Z"] {
        #expect(Client.isSnapshot(name), "\(name)")
    }
    for name in ["", "host/my-mac", "vm/100/2026-11-12T14:00:05Z", "host/../2026-11-12T14:00:05Z", "host/-x/2026-11-12T14:00:05Z",
                 "host/.x/2026-11-12T14:00:05Z", "host/a/b/2026-11-12T14:00:05Z", "host/my mac/2026-11-12T14:00:05Z",
                 "host/mäc/2026-11-12T14:00:05Z", "host/my-mac/2026-11-12 14:00:05", "host/my-mac/2026-11-12T14:00:05Z/..",
                 "/host/my-mac/2026-11-12T14:00:05Z", snapshot + "\n", "--repository=other@pbs@example.net:store"] {
        #expect(!Client.isSnapshot(name), "\(name)")
    }
    for name in ["Downloads.pxar", "My_Files__old_.pxar", "a.b-c_d.pxar", "_.pxar"] {
        #expect(Client.isArchive(name), "\(name)")
    }
    for name in ["", ".pxar", "Downloads", "Downloads.pxar.didx", "-x.pxar", "--keyfile=x.pxar", "../x.pxar", "a/b.pxar",
                 ".hidden.pxar", "a..pxar", "Down loads.pxar", "Dównloads.pxar", "Downloads.pxar\n"] {
        #expect(!Client.isArchive(name), "\(name)")
    }
}

@Test func theHomeFolderComesFromTheUserDatabase() {
    #expect(Paths.home.path == String(cString: getpwuid(getuid()).pointee.pw_dir))
    #expect(Paths.home.appendingPathComponent("Library").path == Paths.home.path + "/Library")
}

@Test func aPathInAnArchiveNeverStartsWithADash() {
    #expect(Client.pathArgument("") == "/")
    #expect(Client.pathArgument("-x") == "/-x")
    #expect(Client.pathArgument("--repository=other@pbs@example.net:store/a") == "/--repository=other@pbs@example.net:store/a")
}

/// A copy of one of Apple's programs with the signature anyone can make: ad hoc, no developer.
private func adHocCopy(of program: String, in folder: URL) throws -> URL {
    let copy = folder.appendingPathComponent((program as NSString).lastPathComponent)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.copyItem(atPath: program, toPath: copy.path)
    let signed = tool("/usr/bin/codesign", ["--force", "--sign", "-", copy.path])
    try #require(signed.status == 0, "\(signed.output)")
    return copy
}

@Test func aFileIsOnlyTheTeamsWhenItsSignatureSaysSo() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pbs-mackup-signed-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let team = try #require(Signature.requirement(team: "33C888LZ98")), apple = try #require(Signature.requirement("anchor apple"))
    // A Team ID is letters and digits; anything else would be read as part of the requirement.
    #expect(Signature.requirement(team: "") == nil)
    #expect(Signature.requirement(team: "X\" or anchor apple generic or \"") == nil)

    let system = URL(fileURLWithPath: "/usr/bin/true")
    #expect(Signature.isSigned(system, as: apple))
    #expect(!Signature.isSigned(system, as: team))                          // signed, by somebody else
    #expect(!Signature.isSigned(try adHocCopy(of: system.path, in: folder), as: team))   // signed by nobody
    let script = folder.appendingPathComponent("script")
    try Data("#!/bin/sh\n".utf8).write(to: script)
    #expect(!Signature.isSigned(script, as: team))                          // not signed at all
    #expect(!Signature.isSigned(folder.appendingPathComponent("not-there"), as: team))
}

/// With the app installed, its client is what the installed run tool would start: signed by the
/// team that signed the tool. Only reads the two signatures. Not on a Mac without the app, such
/// as the one that builds the releases.
@Test(.enabled(if: FileManager.default.fileExists(atPath: "/Applications/PBSMackup.app/Contents/Helpers/proxmox-backup-client")))
func theInstalledClientIsSignedByTheTeamOfTheInstalledRunTool() throws {
    var tool: SecStaticCode?
    SecStaticCodeCreateWithPath(URL(fileURLWithPath: "/Applications/PBSMackup.app/Contents/MacOS/pbs-mackup-run") as CFURL, [], &tool)
    // An app someone built for themselves without a developer's identity names no team.
    guard let team = Signature.team(in: try #require(tool)) else { return }
    let client = URL(fileURLWithPath: "/Applications/PBSMackup.app/Contents/Helpers/proxmox-backup-client")
    let signed = try #require(Signature.requirement(team: team))
    #expect(Signature.isSigned(client, as: signed))
    #expect(!Signature.isSigned(client, as: try #require(Signature.requirement(team: "AAAAAAAAAA"))))
    // What is asked of the ordinary client on top, that it may not load other developers'
    // libraries, a program of the team meets that never could: the run tool. (Not looked at
    // here: the installed client, which could in versions before this was asked.)
    let ordinary = try #require(Signature.withoutForeignLibraries(signed))
    #expect(Signature.isSigned(URL(fileURLWithPath: "/Applications/PBSMackup.app/Contents/MacOS/pbs-mackup-run"), as: ordinary))
}

@Test func aRunningProgramIsJudgedByWhatRuns() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pbs-mackup-running-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let team = try #require(Signature.requirement(team: "33C888LZ98")), apple = try #require(Signature.requirement("anchor apple"))
    func sleeping(_ program: URL) throws -> Process {
        let process = Process()
        process.executableURL = program
        process.arguments = ["30"]
        try process.run()
        return process
    }
    let system = try sleeping(URL(fileURLWithPath: "/bin/sleep"))
    defer { system.terminate() }
    let code = try #require(Signature.running(system.processIdentifier))
    #expect(Signature.isSigned(code, as: apple))
    #expect(!Signature.isSigned(code, as: team))
    #expect(Signature.signer(of: code) == .unknown)                         // Apple's own: no team, and not ad hoc

    let copy = try sleeping(try adHocCopy(of: "/bin/sleep", in: folder))
    defer { copy.terminate() }
    let copied = try #require(Signature.running(copy.processIdentifier))
    #expect(!Signature.isSigned(copied, as: team) && !Signature.isSigned(copied, as: apple))
    #expect(Signature.signer(of: copied) == .nobody)                        // what a development build is

    let ended = try sleeping(URL(fileURLWithPath: "/usr/bin/true"))
    ended.waitUntilExit()
    #expect(Signature.running(ended.processIdentifier) == nil)
}

@Test func theOrdinaryClientMayNotLoadOtherDevelopersLibraries() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pbs-mackup-entitled-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    // One program twice under one name, as the app holds its client: once plain, and once
    // signed like the copy for `mount`, with the entitlements the build gives that copy.
    let entitlements = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Scripts/client.entitlements")
    func copy(in name: String, _ options: [String] = []) throws -> URL {
        let copy = try adHocCopy(of: "/bin/sleep", in: folder.appendingPathComponent(name))
        let signed = tool("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "pbs-mackup-test-client"] + options + [copy.path])
        try #require(signed.status == 0, "\(signed.output)")
        return copy
    }
    let plain = try copy(in: "plain"), mounting = try copy(in: "mount", ["--entitlements", entitlements.path])
    // The name stands in for the team, which a signature anyone can make does not have.
    let named = try #require(Signature.requirement("identifier \"pbs-mackup-test-client\""))
    let ordinary = try #require(Signature.withoutForeignLibraries(named))
    #expect(Signature.isSigned(plain, as: named) && Signature.isSigned(plain, as: ordinary))
    #expect(Signature.isSigned(mounting, as: named))            // good for `mount`,
    #expect(!Signature.isSigned(mounting, as: ordinary))        // and for nothing else
    #expect(!Signature.isSigned(URL(fileURLWithPath: "/bin/sleep"), as: ordinary))     // the name is still asked for

    // The same of what runs.
    for (program, passes) in [(plain, true), (mounting, false)] {
        let running = try Child(program, ["30"])
        defer { running.signal(SIGKILL); running.wait() }
        let code = try #require(Signature.running(running.pid))
        #expect(Signature.isSigned(code, as: named))
        #expect(Signature.isSigned(code, as: ordinary) == passes)
    }
}

/// What `mount` loads into a client that holds the token and the key has to be the system's
/// alone to change. In a folder of the test's own, where the test's user stands in for root.
@Test func whatAMountLoadsHasToBeTheSystemsAloneToChange() throws {
    // Named without the link that the way to the temporary folder goes through.
    let base = URL(fileURLWithPath: Config.realPath(NSTemporaryDirectory())).appendingPathComponent("pbs-mackup-fuse-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    func path(_ name: String) -> String { base.path + "/" + name }
    func mode(_ mode: Int, _ name: String) throws { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path(name)) }
    for folder in ["lib", "bin", "elsewhere/bin"] {
        try FileManager.default.createDirectory(atPath: path(folder), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    }
    for file in ["lib/library", "elsewhere/bin/helper-1.2"] {
        try Data("x".utf8).write(to: URL(fileURLWithPath: path(file)))
        try mode(0o755, file)
    }
    // As FUSE-T installs its helper: a link in one folder to a file in another.
    try FileManager.default.createSymbolicLink(atPath: path("bin/helper"), withDestinationPath: "../elsewhere/bin/helper-1.2")
    /// What could be exchanged on the way to `name`, named from the test's folder on.
    func exchangeable(_ name: String) -> String? {
        Client.exchangeable(path(name), owners: [0, getuid()]).map { String($0.dropFirst(base.path.count)) }
    }

    #expect(exchangeable("lib/library") == nil)
    #expect(exchangeable("bin/helper") == nil)
    #expect(exchangeable("bin/not-there") == nil)                // nobody else can make it there either
    // With root alone to be trusted, as `mount` asks, the first folder of the user's on the way is named.
    let first = try #require(Client.exchangeable(path("lib/library")))
    #expect(base.path.hasPrefix(first) && first != "/")

    // A file, the folder it is in, a folder above: each open to the group or to everyone.
    try mode(0o775, "lib/library")
    #expect(exchangeable("lib/library") == "/lib/library")
    try mode(0o755, "lib/library")
    try mode(0o757, "lib")
    #expect(exchangeable("lib/library") == "/lib")
    try mode(0o755, "lib")
    // Where a link leads counts like the way to the link: the helper's own folder, as
    // Homebrew leaves /usr/local/bin on an Intel Mac, and the folder the link points into.
    try mode(0o775, "bin")
    #expect(exchangeable("bin/helper") == "/bin")
    try mode(0o755, "bin")
    try mode(0o775, "elsewhere")
    #expect(exchangeable("bin/helper") == "/elsewhere")
    try mode(0o755, "elsewhere")
    try mode(0o777, "elsewhere/bin/helper-1.2")
    #expect(exchangeable("bin/helper") == "/elsewhere/bin/helper-1.2")
    try mode(0o755, "elsewhere/bin/helper-1.2")
    #expect(exchangeable("bin/helper") == nil)
    // A link that leads round in a circle leads nowhere good.
    try FileManager.default.createSymbolicLink(atPath: path("bin/round"), withDestinationPath: "round")
    #expect(exchangeable("bin/round") == "/bin/round")

    #expect(Client.fuseTExchangeable("/usr/local/lib").contains("/usr/local/lib does not belong to the system alone"))
}

extension PrivateHomeTests {
@Test func aClientThatIsNotTheDevelopersGetsNeitherTokenNorKey() throws {
    let home = try Home()
    defer { home.remove() }
    try Keychain.set(.token, Data("right-token".utf8))
    try Keychain.set(.encryptionKey, Data("KEY".utf8))
    let client = try Client(config: home.config)
    let arguments = ["catalog", "list", snapshot, "Downloads.pxar", "/"]
    func start(usesKey: Bool = true, signedAs requirement: SecRequirement?) throws -> Child {
        try client.start(arguments, usesKey: usesKey, executable: client.executable, signedAs: requirement)
    }

    // The stand-in is a script nobody signed: asked for a team's client, it is not started.
    let team = try #require(Signature.requirement(team: "33C888LZ98"))
    #expect(failure { _ = try start(signedAs: team) }?.contains("so it was not started") == true)
    #expect(home.noted("program") == nil)

    // A file that passes and a program that does not: the script is now signed under a name,
    // but what runs it is /bin/sh. It is started, and stopped before it gets anything. That
    // goes for a command without a key as well: it would still get the token.
    let signed = tool("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "pbs-mackup-test-client", client.executable.path])
    try #require(signed.status == 0, "\(signed.output)")
    let named = try #require(Signature.requirement("identifier \"pbs-mackup-test-client\""))
    #expect(Signature.isSigned(client.executable, as: named))
    for usesKey in [true, false] {
        #expect(failure { _ = try start(usesKey: usesKey, signedAs: named) }?.contains("stopped before it got the token or the key") == true)
        #expect(home.noted("input") != "KEY")
        #expect(home.noted("token") == nil)
    }

    // Nothing is asked of a development build's client.
    #expect(try start(signedAs: nil).finish().status == 0)
    #expect(home.noted("input") == "KEY")
    #expect(home.noted("token") == "right-token\n")
}

@Test func theSnapshotIsMountedInTheCacheByADevelopmentBuild() throws {
    let home = try Home()
    defer { home.remove() }
    #expect(Identity.team == nil)
    #expect(Paths.mount.path == home.folder.appendingPathComponent("cache/mnt").path)
    try Paths.createFolders()
    #expect(FileManager.default.fileExists(atPath: Paths.cache.path))
    #expect(!FileManager.default.fileExists(atPath: Paths.mount.path))       // made when a snapshot is mounted
}

@Test func theClientsEnvironmentIsBuiltFromScratch() {
    // What `launchctl setenv` or a parent process could have put there.
    let environment = Client.environment(inherited: [
        "HOME": "/tmp/elsewhere", "USER": "nobody", "LOGNAME": "nobody", "TMPDIR": "/tmp/elsewhere", "PATH": "/tmp/elsewhere/bin",
        "LANG": "de_DE.UTF-8", "SSL_CERT_FILE": "/tmp/roots.pem", "SSL_CERT_DIR": "/tmp/roots", "OPENSSL_CONF": "/tmp/openssl.cnf",
        "ALL_PROXY": "http://127.0.0.1:1", "PBS_REPOSITORY": "other@pbs@example.net:store", "PBS_FINGERPRINT_CMD": "/tmp/elsewhere/bin/x",
        "PBS_PASSWORD_FILE": "/tmp/elsewhere/token", "CREDENTIALS_DIRECTORY": "/tmp/elsewhere", "XDG_CONFIG_HOME": "/tmp/elsewhere",
        "DYLD_INSERT_LIBRARIES": "/tmp/elsewhere/x.dylib", "PBS_MACKUP_STUB": "ok"])
    #expect(environment == [
        "HOME": Paths.home.path, "USER": NSUserName(), "LOGNAME": NSUserName(),
        "TMPDIR": NSTemporaryDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "de_DE.UTF-8",
        "SSL_CERT_FILE": "/etc/ssl/cert.pem", "SSL_CERT_DIR": "/etc/ssl/certs", "OPENSSL_CONF": "/dev/null",
        "PBS_MACKUP_STUB": "ok"])              // only a development build passes PBS_MACKUP_ on, for the stand-in client
    #expect(Client.environment(inherited: [:])["LANG"] == nil)
}

@Test func aClientIsStartedWithWhatItNeedsAndNothingElse() throws {
    let home = try Home()
    defer { home.remove() }
    try Keychain.set(.token, Data("right-token\n".utf8))
    try Keychain.set(.encryptionKey, Data("KEY".utf8))
    let planted = ["SSL_CERT_FILE": "/tmp/roots.pem", "ALL_PROXY": "http://127.0.0.1:1", "PBS_FINGERPRINT_CMD": "/usr/bin/true"]
    for (name, value) in planted { setenv(name, value, 1) }
    defer { for name in planted.keys { unsetenv(name) } }
    let client = try Client(config: home.config)

    try client.checkConnection()
    var environment = home.environment
    #expect(environment["PBS_REPOSITORY"] == home.config.repository)
    // The token is on descriptor 3, one line. It is not in the environment or the arguments,
    // which `ps` shows to every program of the user.
    #expect(home.noted("token") == "right-token\n")
    #expect(environment["PBS_PASSWORD_FD"] == "3")
    #expect(environment["PBS_PASSWORD"] == nil)
    #expect(home.noted("environment")?.contains("right-token") == false)
    #expect(environment["PBS_FINGERPRINT"] == nil)
    #expect(environment["SSL_CERT_FILE"] == "/etc/ssl/cert.pem")
    #expect(environment["ALL_PROXY"] == nil)
    #expect(environment["PBS_FINGERPRINT_CMD"] == nil)
    #expect(environment["HOME"] == home.folder.path)                 // the client's own files stay in the private home
    #expect(home.noted("arguments") == "snapshot\nlist\nhost/test-mac\n--output-format\njson\n--ns\ntest\n")
    #expect(home.noted("input") == "")                               // a command that takes no key gets none

    var pinned = home.config
    pinned.fingerprint = "aa:bb"
    #expect(try Client(config: pinned).list(snapshot: snapshot, archive: "Downloads.pxar", path: "").isEmpty)
    environment = home.environment
    #expect(environment["PBS_FINGERPRINT"] == "aa:bb")
    #expect(home.noted("arguments") == "catalog\nlist\n\(snapshot)\nDownloads.pxar\n/\n--ns\ntest\n--keyfd\n0\n")
    #expect(home.noted("input") == "KEY")
}

@Test func mountingUsesItsOwnCopyOfTheClientWhereThereIsOne() throws {
    let home = try Home()
    defer { home.remove() }
    try Keychain.set(.token, Data("right-token".utf8))
    try Keychain.set(.encryptionKey, Data("KEY".utf8))
    let client = try Client(config: home.config)
    #expect(client.mountExecutable.path == client.executable.path)   // a development build has one client
    let copy = client.executable.deletingLastPathComponent().appendingPathComponent("proxmox-backup-client-mount")
    try FileManager.default.copyItem(at: client.executable, to: copy)
    #expect(client.mountExecutable.path == copy.path)

    // Everything but `mount` still runs the first one.
    try client.checkConnection()
    #expect(home.noted("program") == client.executable.path + "\n")
    if Client.canMount, Client.fuseT.allSatisfy({ Client.exchangeable($0) == nil }) {
        // The stand-in mounts nothing, which is an error, but it was the copy that was asked.
        #expect(failure { _ = try client.mount(snapshot: snapshot, archive: "Downloads.pxar") } == "The backup could not be mounted.")
        #expect(home.noted("program") == copy.path + "\n")
        #expect(home.noted("input") == "KEY")
    }
}

@Test func whatTheServerListsUnderAnotherNameIsLeftOut() throws {
    let home = try Home()
    defer { home.remove() }
    try Keychain.set(.token, Data("right-token".utf8))
    let time = Int(try #require(ISO8601DateFormatter().date(from: "2026-11-12T14:00:05Z")).timeIntervalSince1970)
    try home.answer("""
        [{"backup-type":"host","backup-id":"test-mac","backup-time":\(time),"size":5,"files":[
            {"filename":"Downloads.mpxar.didx"},{"filename":"../../../evil.pxar.didx"},{"filename":"-x.pxar.didx"},
            {"filename":"--keyfile=x.pxar.didx"},{"filename":"index.json.blob"}]},
         {"backup-type":"host","backup-id":"../../elsewhere","backup-time":\(time),"files":[{"filename":"Downloads.pxar.didx"}]},
         {"backup-type":"--repository=other@pbs@example.net:store","backup-id":"x","backup-time":\(time),"files":[]},
         {"backup-type":"host","backup-id":"test-mac","backup-time":99999999999999,"files":[]}]
        """)
    let snapshots = try Client(config: home.config, needsKey: false).snapshots()
    #expect(snapshots.map(\.name) == [snapshot])
    #expect(snapshots.first?.archives == ["Downloads.pxar"])
}

@Test func namesAreCheckedBeforeTheClientIsStarted() throws {
    let home = try Home()
    defer { home.remove() }
    try Keychain.set(.token, Data("right-token".utf8))
    try Keychain.set(.encryptionKey, Data("KEY".utf8))
    let client = try Client(config: home.config)
    let option = "--repository=other@pbs@example.net:store"
    #expect(failure { _ = try client.list(snapshot: option, archive: "Downloads.pxar", path: "") }?.contains("is not a snapshot") == true)
    #expect(failure { _ = try client.list(snapshot: snapshot, archive: "../x.pxar", path: "") }?.contains("is not an archive") == true)
    #expect(failure { _ = try client.restore(snapshot: snapshot, archive: "-x.pxar", path: "a", into: home.folder) } != nil)
    #expect(failure { _ = try client.restore(snapshot: "host/../../x/2026-11-12T14:00:05Z", archive: "a.pxar", path: "a", into: home.folder) } != nil)
    #expect(failure { _ = try client.versions(archive: "../x.pxar", path: "a") } != nil)
    #expect(failure { _ = try client.index(snapshot: "host/../../x/2026-11-12T14:00:05Z", archives: ["Downloads.pxar"]) } != nil)
    #expect(failure { _ = try client.index(snapshot: snapshot, archives: ["Downloads.pxar", "../x.pxar"]) } != nil)
    #expect(failure { _ = try client.mount(snapshot: snapshot, archive: "../x.pxar") }?.contains("is not an archive") == true)
    #expect(home.noted("arguments") == nil)                          // the client was never started,
    #expect(!FileManager.default.fileExists(atPath: Paths.cache.path))   // and nothing was made in the cache

    // A folder in a backup can be called anything. It reaches the client as a path, not as an option.
    #expect(try client.list(snapshot: snapshot, archive: "Downloads.pxar", path: option).isEmpty)
    #expect(home.noted("arguments") == "catalog\nlist\n\(snapshot)\nDownloads.pxar\n/\(option)\n--ns\ntest\n--keyfd\n0\n")
}

@Test func settingsAreOnlyStoredOnceTheServerAcceptedThem() throws {
    let home = try Home()
    defer { home.remove() }
    // Nothing is stored yet, and the server turns the token down: nothing is stored.
    #expect(failure { try Client.accept(home.config, token: Data("wrong-token".utf8)) } == "permission check failed")
    #expect(home.noted("token") == "wrong-token\n")                 // it was the candidate that was tried
    #expect(try Keychain.get(.token) == nil)
    #expect((try? Config.load()) == nil)
    #expect(failure { try Client.accept(home.config) } == "The API token is not in the Keychain.")

    try Client.accept(home.config, token: Data("right-token".utf8))
    #expect(try Keychain.get(.token) == Data("right-token".utf8))
    #expect(try Config.load() == home.config)
    #expect(home.noted("input") == "")                               // the check needs no key, and there is none yet

    // A change the server refuses leaves both as they were.
    var changed = home.config
    changed.namespace = "other"
    #expect(failure { try Client.accept(changed, token: Data("wrong-token".utf8)) } == "permission check failed")
    #expect(home.noted("arguments")?.hasSuffix("--ns\nother\n") == true)
    #expect(try Keychain.get(.token) == Data("right-token".utf8))
    #expect(try Config.load() == home.config)

    // Without a token, or with an empty one, the stored token is tried and stays.
    try Client.accept(changed)
    #expect(home.noted("token") == "right-token\n")
    #expect(try Config.load() == changed)
    try Client.accept(home.config, token: Data())
    #expect(try Keychain.get(.token) == Data("right-token".utf8))
    #expect(try Config.load() == home.config)

    // A configuration that cannot be written takes the new token back with it.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: Paths.support.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Paths.support.path) }
    #expect(failure { try Client.accept(changed, token: Data("right-new-token".utf8)) } != nil)
    #expect(home.noted("token") == "right-new-token\n")             // the server had accepted it
    #expect(try Keychain.get(.token) == Data("right-token".utf8))
    #expect(try Config.load() == home.config)
}

/// The fork's command line parser, which `Client.pathArgument` is written for. Runs with the real
/// client when PBS_MACKUP_CLIENT names one; nothing listens where it is sent.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PBS_MACKUP_CLIENT"].map(FileManager.default.isExecutableFile) == true))
func theRealClientTakesAPathWithALeadingDashAsAPath() throws {
    let home = try Home()
    defer { home.remove() }
    try Keychain.set(.token, Data("right-token".utf8))
    try Keychain.set(.encryptionKey, Data("KEY".utf8))
    var config = home.config
    config.clientPath = ProcessInfo.processInfo.environment["PBS_MACKUP_CLIENT"]
    let client = try Client(config: config)
    // Handed over as it is, a name with a leading dash is an option, and `--` does not change that.
    #expect(failure { _ = try client.capture(["catalog", "list", snapshot, "Downloads.pxar", "-x"]) }?.contains("parameter verification failed") == true)
    #expect(failure { _ = try client.capture(["catalog", "list", snapshot, "Downloads.pxar", "--", "-x"]) }?.contains("additional arguments") == true)
    // As `list` hands it over, the client has nothing to say about its arguments.
    let listed = try #require(failure { _ = try client.list(snapshot: snapshot, archive: "Downloads.pxar", path: "-x") })
    #expect(!listed.contains("parameter") && !listed.contains("arguments"), "\(listed)")

    // The same for a pattern to leave out: after its option it is an option itself, in one
    // piece with it it is the pattern, and the client goes on to the server, which is not there.
    let backup = ["backup", "Source.pxar:\(home.folder.path)", "--backup-id", "test-mac"]
    #expect(failure { _ = try client.capture(backup + ["--exclude", "-x"], usesKey: false) }?.contains("parameter verification failed") == true)
    #expect(failure { _ = try client.capture(backup + ["--exclude=-x", "--exclude=--ns", "--exclude=a=b"], usesKey: false) } == "client error (Connect)")
}

/// The fork's way of taking the token, which `Client.start` is written for: from the descriptor
/// that `PBS_PASSWORD_FD` names. Runs with the real client when PBS_MACKUP_CLIENT names one;
/// nothing listens where it is sent, so how far it gets is what there is to see.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PBS_MACKUP_CLIENT"].map(FileManager.default.isExecutableFile) == true))
func theRealClientTakesTheTokenFromItsDescriptor() throws {
    let home = try Home()
    defer { home.remove() }
    try Keychain.set(.token, Data("right-token".utf8))
    var config = home.config
    config.clientPath = ProcessInfo.processInfo.environment["PBS_MACKUP_CLIENT"]
    let client = try Client(config: config, needsKey: false)
    // Started as every client is, it has a token and goes on to the server, which is not there.
    #expect(failure { try client.checkConnection() } == "client error (Connect)")

    // The same call with the same environment, started by hand.
    let arguments = ["snapshot", "list", "host/test-mac", "--output-format", "json", "--ns", "test"]
    var environment = Client.environment()
    environment["PBS_REPOSITORY"] = config.repository
    func errors(_ input: [Int32: Data]) throws -> String {
        String(decoding: try Child(client.executable, arguments, environment: environment, input: input).finish().errors, as: UTF8.self)
    }
    // Without a token anywhere it stops before it connects.
    #expect(try errors([:]).contains("API token secret must be provided"))
    // Told to read descriptor 3, it takes what is there: a line is a token, with or without
    // its end, and it goes on to the server; bytes that are no text are turned down as such.
    environment["PBS_PASSWORD_FD"] = "3"
    #expect(try errors([3: Data("right-token\n".utf8)]).contains("Error: client error (Connect)"))
    #expect(try errors([3: Data("right-token".utf8)]).contains("Error: client error (Connect)"))
    #expect(try errors([3: Data([0xFF, 0xFE, 0x0A])]).contains("stream did not contain valid UTF-8"))
}
}
