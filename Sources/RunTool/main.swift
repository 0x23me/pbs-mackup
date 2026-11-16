import Foundation
import LocalAuthentication
import os
import PBSMackupKit

// pbs-mackup-run makes one backup run and exits; launchd starts it that way. With a command it
// does one thing. `commands` below is the list of what the tool takes, and says of each who may
// ask for it. The app asks over the connection of the helper job (`serve`), which takes
// messages from nobody but the app. Anyone else starts the tool as a program, as the owner does
// at a terminal and as any other program of the owner can: there a command that reads the
// backups or changes the settings or the secrets first has the owner confirm with Touch ID or
// the password. So does the helper of a build no developer signed, which cannot tell the app
// from any other program. `carryOut` is the one way to a command for all of them.

setvbuf(stdout, nil, _IOLBF, 0)

/// Who asks for a command. `Command.callers` names the ones a command is for.
enum Caller {
    /// Whoever started the tool as a program of the owner: the owner at a terminal, launchd for
    /// one of the owner's jobs, any other program of the owner.
    case terminal
    /// The app, over the helper's connection.
    case app
    /// Whoever started the tool as root: an administrator with sudo, launchd for its daemon.
    case root
}

/// One call of a command.
struct Call {
    /// The command's name and what follows it.
    let arguments: [String]
    /// What the command finds in the place of standard input.
    let input: () -> Data
    let caller: Caller
    /// Whether the owner confirms what the command has confirmed (`Command.confirm`). Not for
    /// the app where macOS has checked by its signature that it is the app. For everyone else:
    /// who starts the tool as a program, and who comes over the helper's connection of a build
    /// no developer signed, where there is no signature to check and so no telling who it is.
    let confirms: Bool
    /// Whether macOS has checked by its signature that the caller is the app. A program the
    /// owner confirmed once over the helper of a build no developer signed is not asked again
    /// (`confirms` is false), but nothing vouches for it: what asks whoever is not vouched for,
    /// a first key say, still asks it.
    let vouched: Bool
    /// Called once the owner has confirmed this call.
    var confirmed: () -> Void = {}
}

func json<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder.iso8601.encode(value) }

/// Has the owner confirm with Touch ID or the login password. The Keychain hands the token and
/// the key to this tool without asking and any program of this user can start this tool, so
/// this question is what keeps such a program from them. `reason` ends the sentence "… is
/// trying to". A Mac without a password has nothing to ask for and goes ahead.
func confirmOwner(to reason: String) throws {
    #if DEBUG
    // Tests and development keep their secrets in files under PBS_MACKUP_HOME and never show a
    // question. A test that wants to know whether one would be shown has it turned down.
    let environment = ProcessInfo.processInfo.environment
    if environment["PBS_MACKUP_HOME"] != nil {
        guard environment["PBS_MACKUP_CONFIRM"] != "refuse" else {
            throw Failure(description: "Not confirmed: \(reason)")
        }
        return
    }
    #endif
    let context = LAContext()
    let answered = DispatchSemaphore(value: 0)
    var refusal: Error?
    context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { confirmed, error in
        if !confirmed { refusal = error ?? LAError(.authenticationFailed) }
        answered.signal()
    }
    withExtendedLifetime(context) { answered.wait() }      // the question goes away with its context
    if let refusal, (refusal as? LAError)?.code != .passcodeNotSet {
        throw Failure(description: "Nothing was done, because macOS did not confirm that it is you: \(refusal.localizedDescription)")
    }
}

/// Before a key goes into the Keychain. A key that takes the place of another is confirmed
/// whoever asks, the app included: with a key of its own in there, another program could read
/// every later backup and the owner's recovery copy none. A first key is confirmed when it is
/// not known to come from the app: "first" is only what the Keychain says, and any program can
/// delete an item.
func confirmKeyChange(_ call: Call) throws {
    if try Keychain.get(.encryptionKey) != nil {
        try confirmOwner(to: "replace the encryption key of your backups")
    } else if !call.vouched {
        try confirmOwner(to: "set the encryption key of your backups")
    }
}

/// One backup run.
func backUp(_ config: Config, _ trigger: Trigger, readEverything: Bool = false) -> Never {
    let runner = Runner(config: config, trigger: trigger, readEverything: readEverything)
    var sources: [DispatchSourceSignal] = []
    for number in [SIGTERM, SIGINT] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { runner.cancel() }
        source.resume()
        sources.append(source)
    }
    withExtendedLifetime(sources) { exit(runner.run().rawValue) }
}

/// One thing the tool does. The usage text and the choice of what to run both come from
/// `commands`, so a new command is one entry there.
struct Command {
    /// The first argument; nil for none at all.
    let name: String?
    /// What follows the name, as the usage text shows it.
    var arguments = ""
    /// How many arguments may follow the name. Where nothing is said they are not counted.
    var count = 0...Int.max
    let what: String
    /// Who may ask for it; anyone else is refused before anything is done, see `carryOut`.
    /// Nobody where nothing is said, so that a new command says whom it is for.
    var callers: Set<Caller> = []
    /// What the owner is asked to confirm when the command is not known to come from the app
    /// (`Call.confirms`); it ends the sentence "… is trying to". Nil for a command that gives
    /// nothing away and changes nothing that matters, and for one that asks by itself.
    var confirm: String? = nil
    let run: Run

    enum Run {
        /// A backup run: only ever a program of its own, started by launchd or by hand.
        case backup(Trigger, readEverything: Bool)
        /// The helper, which answers the app; what launchd starts for it.
        case serve
        case plain((Call) throws -> Data)
        /// Needs the configuration, and only goes by one the app or the tool stored.
        case configured((Call, Config) throws -> Data)
    }
}

let commands: [Command] = [
    // A run and the helper are programs of their own, which launchd starts as it starts anything
    // of the owner's; nobody asks the helper for them.
    Command(name: nil, what: "one scheduled run (what launchd starts)", callers: [.terminal], run: .backup(.scheduled, readEverything: false)),
    Command(name: "--manual", what: "one run started by hand: ignores the battery condition and the interval",
            callers: [.terminal], run: .backup(.manual, readEverything: false)),
    Command(name: "--full", what: "the same, and reads every folder instead of only those that changed",
            callers: [.terminal], run: .backup(.manual, readEverything: true)),
    Command(name: "serve", what: "answer the app over its connection (what launchd starts for it)", callers: [.terminal], run: .serve),
    Command(name: "status", what: "print the state file", callers: [.terminal],
            run: .plain { _ in (try? Data(contentsOf: Paths.state)) ?? Data("no run yet".utf8) }),

    // What follows prints JSON. The app asks for the ones that name it; whoever is not known to
    // be the app has the owner confirm first.
    Command(name: "snapshots", what: "the snapshots, newest first", callers: [.app, .terminal], confirm: "list your backups",
            run: .configured { _, config in try json(Client(config: config).snapshots()) }),
    Command(name: "settings", arguments: "<snapshot>", count: 1...1, what: "the settings manifest of a snapshot",
            callers: [.app, .terminal], confirm: "read the settings recorded in your backups",
            run: .configured { call, config in try json(Client(config: config).settings(snapshot: call.arguments[1])) }),
    Command(name: "list", arguments: "<snapshot> <archive> [<path>]", count: 2...3, what: "one directory",
            callers: [.app, .terminal], confirm: "read the names in your backups",
            run: .configured { call, config in
                let arguments = call.arguments
                return try json(Client(config: config).list(snapshot: arguments[1], archive: arguments[2],
                                                            path: arguments.count > 3 ? arguments[3] : ""))
            }),
    Command(name: "restore", arguments: "<snapshot> <archive> <path> <folder> [keep-both|replace|skip]", count: 4...5,
            what: "restore one item into a folder; keep-both when not said",
            callers: [.app, .terminal], confirm: "restore files from your backups",
            run: .configured { call, config in
                struct Restored: Encodable { let restored: String? }
                let arguments = call.arguments
                guard let conflict = Client.Conflict(rawValue: arguments.count == 6 ? arguments[5] : "keep-both") else {
                    throw Failure(description: "The last argument is keep-both, replace or skip.")
                }
                let restored = try Client(config: config).restore(snapshot: arguments[1], archive: arguments[2], path: arguments[3],
                                                                  into: URL(fileURLWithPath: arguments[4]), conflict: conflict)
                return try json(Restored(restored: restored?.path))
            }),
    Command(name: "versions", arguments: "<archive> <path>", count: 2...2, what: "the versions of one item, newest first",
            callers: [.app, .terminal], confirm: "read the names in your backups",
            run: .configured { call, config in
                try json(Client(config: config).versions(archive: call.arguments[1], path: call.arguments[2]))
            }),
    Command(name: "index", arguments: "<snapshot> <archive>...", count: 2...Int.max,
            what: "write the names in these archives into a file, for searching; prints the file",
            callers: [.app, .terminal], confirm: "read the names in your backups",
            run: .configured { call, config in
                try json(["index": Client(config: config).index(snapshot: call.arguments[1],
                                                                archives: Array(call.arguments.dropFirst(2))).path])
            }),
    // With Full Disk Access the tool reads any folder, Mail and Messages included, and the file
    // it writes names what is big in there: the owner confirms this one as well.
    Command(name: "sizes", arguments: "<folder>", count: 1...1,
            what: "measure a folder and what is in it, for choosing what to leave out; prints the file",
            callers: [.app, .terminal], confirm: "read the names and sizes of what is in your folders",
            run: .plain { call in try json(["sizes": FolderSizes.measure(call.arguments[1]).save().path]) }),
    Command(name: "check", what: #"{"ok":true} when the server accepts repository, namespace and token"#,
            callers: [.terminal],
            run: .configured { _, config in
                try Client(config: config, needsKey: false).checkConnection()
                return try json(["ok": true])
            }),
    Command(name: "accept",
            what: #"store the settings on standard input, {"config":{…},"token":"…"}, once the server accepts them; without "token" the stored one is tried"#,
            callers: [.app, .terminal], confirm: "change where your backups go",
            run: .plain { call in
                /// `config` as in config.json; `token` only when a new one was typed in.
                struct Candidate: Decodable { let config: Config, token: String? }
                guard let candidate = try? JSONDecoder().decode(Candidate.self, from: call.input()) else {
                    throw Failure(description: #"Standard input should be {"config":{…},"token":"…"}, with the configuration as in config.json."#)
                }
                try Client.accept(candidate.config, token: candidate.token.map { Data($0.utf8) })
                return try json(["ok": true])
            }),
    Command(name: "seal", what: "go by config.json as it is now, after it was edited by hand",
            callers: [.terminal], confirm: "change what is backed up and where to",
            run: .plain { _ in
                try Seal.set(config: Config.load())
                return try json(["ok": true])
            }),
    // The app stores a token this way only after a restore of the home folder, with the token
    // the restore has just worked with; the settings window goes by `accept`.
    Command(name: "set-token", what: "store the API token secret from standard input in the Keychain",
            callers: [.app, .terminal], confirm: "replace the API token of your backups",
            run: .plain { call in
                let token = call.input()
                guard !token.isEmpty else { throw Failure(description: "Nothing on standard input.") }
                try Keychain.set(.token, token)
                return try json(["stored": "token"])
            }),
    Command(name: "set-key", what: "store the encryption key file from standard input in the Keychain",
            callers: [.app, .terminal],
            run: .plain { call in
                try confirmKeyChange(call)
                return try json(KeyStore.importKey(call.input()))
            }),
    Command(name: "unlock-key",
            what: #"store the key file that is locked with a passphrase, from standard input as {"key":"…","passphrase":"…"}, without the passphrase"#,
            callers: [.app, .terminal],
            run: .plain { call in
                /// `key` is the text of the key file, or of a paper key.
                struct Locked: Decodable { let key: String, passphrase: String }
                guard let locked = try? JSONDecoder().decode(Locked.self, from: call.input()) else {
                    throw Failure(description: #"Standard input should be {"key":"…","passphrase":"…"}, with the text of the key file."#)
                }
                try confirmKeyChange(call)
                return try json(KeyStore.importKey(Data(locked.key.utf8), passphrase: locked.passphrase,
                                                   client: Client.executable(clientPath: (try? Config.load())?.clientPath)))
            }),
    Command(name: "create-key", arguments: "[--replace]", count: 0...1,
            what: "make a new encryption key (refused when one exists, unless --replace)",
            callers: [.app, .terminal],
            run: .plain { call in
                let replacing = call.arguments.contains("--replace")
                guard try replacing || !KeyStore.status().present else { throw Failure(description: "There is an encryption key already.") }
                try confirmKeyChange(call)
                return try json(KeyStore.create(client: Client.executable(clientPath: (try? Config.load())?.clientPath),
                                                replacing: replacing))
            }),
    Command(name: "export-key", arguments: "<file>", count: 1...1,
            what: "write the recovery copy of the key, once the owner has confirmed with Touch ID or the password",
            callers: [.app, .terminal],
            run: .plain { call in
                try confirmOwner(to: "export the encryption key of your backups")
                try KeyStore.export(to: URL(fileURLWithPath: call.arguments[1]))
                return try json(["exported": call.arguments[1]])
            }),
    Command(name: "paper-key", what: "the key as text to print, once the owner has confirmed with Touch ID or the password",
            callers: [.app, .terminal],
            run: .plain { _ in
                try confirmOwner(to: "print the encryption key of your backups")
                return try json(["text": KeyStore.paperKey(subject: (try? Config.load())?.backupID ?? "this Mac")])
            }),
    Command(name: "setup-status", what: "which of configuration, token and key exist", callers: [.app, .terminal],
            run: .plain { _ in
                struct SetupStatus: Encodable { let configured: Bool, token: Bool, key: KeyStore.Status }
                return try json(SetupStatus(configured: (try? Config.load()) != nil, token: try Keychain.get(.token) != nil,
                                            key: try KeyStore.status()))
            }),
    Command(name: "restore-daemon", what: "restore a home folder for the app, as root (what launchd starts while the app restores this Mac)",
            callers: [.root],
            run: .plain { _ in
                RestoreService.serve()
            }),
    // Root runs it with sudo, which has the administrator's password already; nothing more is asked.
    Command(name: "restore-home", arguments: restoreHomeArguments,
            what: "with sudo, from another administrator: a user's whole home folder back from a backup, on a new Mac",
            callers: [.root],
            run: .plain { call in try restoreHome(call) }),
    Command(name: "certificate", arguments: "<host> <port>", count: 2...2,
            what: "the server certificate's fingerprint and whether the client takes it without one",
            callers: [.terminal],
            run: .plain { call in
                final class Found: @unchecked Sendable { var info: ServerCertificate.Info? }
                let found = Found(), done = DispatchSemaphore(value: 0)
                let host = call.arguments[1], port = Int(call.arguments[2]) ?? 8007
                Task {
                    found.info = await ServerCertificate.fetch(host: host, port: port)
                    done.signal()
                }
                done.wait()
                guard let info = found.info else { throw Failure(description: "\(host) is not reachable.") }
                return try json(info)
            }),
]

/// How the tool, or the one command that was called wrongly, is used.
func usageText(_ shown: [Command]) -> String {
    var lines = ["usage:"]
    for command in shown {
        lines.append("  " + ["pbs-mackup-run", command.name ?? "", command.arguments].filter { !$0.isEmpty }.joined(separator: " "))
        lines.append("      " + command.what)
    }
    return lines.joined(separator: "\n")
}

func usage(_ shown: [Command]) -> Never {
    print(usageText(shown))
    exit(64)
}

/// Why a call ended before its command ran, where the command line has an exit status of its
/// own for it. The app gets the sentence, like any other error.
enum Stopped: Error, CustomStringConvertible {
    /// Called with the wrong number of arguments: how the command is used.
    case usage(String)
    /// There is no configuration to go by: what is wrong with it.
    case notConfigured(String)

    var description: String {
        switch self {
        case .usage(let text), .notConfigured(let text): return text
        }
    }
}

/// What a caller is told that asks for a command which is not for it.
func refusal(_ command: Command, to caller: Caller) -> String {
    let name = command.name ?? "A backup run"
    switch caller {
    case .app:
        return "\(name) is started from a terminal or by launchd, not by the app."
    case .root:
        return "\(name) is not for root: start it as the user whose backups these are."
    case .terminal:
        return command.callers.contains(.root) ? "\(name) needs root.\n\(usageText([command]))" : "\(name) is only for the app."
    }
}

/// Does one call of a command, and is the one way to a command: the helper and the command
/// line both come through here. In this order: whether this caller may ask for the command at
/// all, the configuration where one is needed (a missing one is said first, whatever else is
/// wrong with the call), the number of arguments, the owner's confirmation, and whether the
/// configuration is one the app or the tool stored. A backup run and the helper do not return.
func carryOut(_ command: Command, _ call: Call) throws -> Data {
    guard command.callers.contains(call.caller) else { throw Failure(description: refusal(command, to: call.caller)) }
    func configuration() throws -> Config {
        do { return try Config.load() } catch {
            throw Stopped.notConfigured("no usable configuration at \(Paths.config.path): \(error.localizedDescription)")
        }
    }
    func countArguments() throws {
        guard command.count.contains(call.arguments.dropFirst().count) else { throw Stopped.usage(usageText([command])) }
    }
    func confirm() throws {
        if call.confirms, let reason = command.confirm {
            try confirmOwner(to: reason)
            call.confirmed()
        }
    }
    switch command.run {
    case .serve:
        try countArguments()
        Helper.serve()
    case .backup(let trigger, let readEverything):
        let config = try configuration()
        try countArguments()
        // Whether its configuration is one to go by the run finds out itself, and says so in its record.
        backUp(config, trigger, readEverything: readEverything)
    case .plain(let run):
        try countArguments()
        try confirm()
        return try run(call)
    case .configured(let run):
        let config = try configuration()
        try countArguments()
        try confirm()
        guard Seal.holds(config) else { throw Failure(description: Seal.configChanged) }
        return try run(call, config)
    }
}

/// Answers the app. In a build a developer signed, every message on a connection comes from a
/// program macOS has checked against the app's signature (`HelperConnection.restrict`), so
/// nothing here asks the owner to confirm, except the commands that do so whoever asks. A build
/// that is only signed ad hoc has no signature to check against, and any program of the owner
/// can connect: there the owner confirms as for a call from a terminal, once for each running
/// program that connects (`ConfirmedCallers`), so that the app's windows do not ask at every
/// click. What changes or hands out the key asks every time all the same.
final class Helper: NSObject, NSXPCListenerDelegate, HelperProtocol {
    private let log = Logger(subsystem: Identity.bundleID, category: "helper")
    private var callers = ConfirmedCallers()
    private let lock = NSLock()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard HelperConnection.restrict(connection, to: Identity.bundleID) else { return false }
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func call(_ arguments: [String], input: Data?, reply: @escaping (Data?, String?) -> Void) {
        let command = commands.first { $0.name == arguments.first }
        let name = command?.name ?? "unknown command"
        do {
            guard let command else { throw Failure(description: "The app asked for something this version of the run tool does not know.") }
            let vouched = HelperConnection.checksCaller
            let pid = NSXPCConnection.current()?.processIdentifier
            let known = lock.withLock { pid.map(callers.holds) ?? false }
            var call = Call(arguments: arguments, input: { input ?? Data() }, caller: .app,
                            confirms: !vouched && !known, vouched: vouched)
            call.confirmed = { [self] in if let pid { lock.withLock { callers.note(pid) } } }
            let answer = try carryOut(command, call)
            log.notice("\(name, privacy: .public): done")
            reply(answer, nil)
        } catch {
            // The error can name files; the command cannot.
            log.error("\(name, privacy: .public): failed: \(String(describing: error))")
            reply(nil, "\(error)")
        }
    }

    static func serve() -> Never {
        // What a call left that was stopped halfway, a key on its way into the Keychain say.
        Scratch.removeLeftovers()
        let helper = Helper()
        let listener = NSXPCListener(machServiceName: Identity.helperLabel)
        listener.delegate = helper
        listener.resume()
        withExtendedLifetime(helper) { dispatchMain() }
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = commands.first(where: { $0.name == arguments.first }) else { usage(commands) }
let started: Caller = geteuid() == 0 ? .root : .terminal
#if DEBUG
// A development build of the app has no helper job and starts the tool as a program, and says
// so. "unchecked" is for the tests: the app's place as the helper of a build no developer
// signed sees it, where nothing vouches that it is the app.
let asApp = ProcessInfo.processInfo.environment["PBS_MACKUP_APP"]
let call = Call(arguments: arguments, input: { FileHandle.standardInput.readDataToEndOfFile() },
                caller: asApp == nil ? started : .app, confirms: asApp == nil || asApp == "unchecked", vouched: asApp == "1")
#else
let call = Call(arguments: arguments, input: { FileHandle.standardInput.readDataToEndOfFile() }, caller: started, confirms: true, vouched: false)
#endif

// Prints what the command made. Its error goes to standard error; how it is used and that
// there is no configuration are said on standard output, each with an exit status of its own.
do {
    FileHandle.standardOutput.write(try carryOut(command, call) + Data("\n".utf8))
    exit(0)
} catch let stopped as Stopped {
    print(stopped)
    switch stopped {
    case .usage: exit(64)
    case .notConfigured: exit(Runner.Exit.notConfigured.rawValue)
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
