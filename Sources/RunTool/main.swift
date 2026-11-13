import Foundation
import LocalAuthentication
import os
import PBSMackupKit

// pbs-mackup-run makes one backup run and exits; launchd starts it that way. With a command it
// does one thing, for one of two callers. The app asks over the connection of the helper job
// (`serve`), which takes messages from nobody but the app. Anyone else starts the tool as a
// program, as the owner does at a terminal and as any other program of the owner can: there a
// command that reads the backups or changes the settings or the secrets first has the owner
// confirm with Touch ID or the password. `commands` below is the list of what the tool takes.

setvbuf(stdout, nil, _IOLBF, 0)

/// Who asks for a command.
enum Caller {
    /// Whoever started the tool as a program.
    case terminal
    /// The app, over the helper's connection.
    case app
}

/// One call of a command.
struct Call {
    /// The command's name and what follows it.
    let arguments: [String]
    /// What the command finds in the place of standard input.
    let input: () -> Data
    let caller: Caller
}

func json<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder.iso8601.encode(value) }

/// Has the owner confirm with Touch ID or the login password. The Keychain hands the token and
/// the key to this tool without asking and any program of this user can start this tool, so
/// this question is what keeps such a program from them. `reason` ends the sentence "… is
/// trying to". A Mac without a password has nothing to ask for and goes ahead.
func confirmOwner(to reason: String) throws {
    #if DEBUG
    // Tests and development keep their secrets in files under PBS_MACKUP_HOME and never show a question.
    if ProcessInfo.processInfo.environment["PBS_MACKUP_HOME"] != nil { return }
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
/// every later backup and the owner's recovery copy none. A first key is confirmed when it does
/// not come from the app: "first" is only what the Keychain says, and any program can delete an item.
func confirmKeyChange(_ call: Call) throws {
    if try Keychain.get(.encryptionKey) != nil {
        try confirmOwner(to: "replace the encryption key of your backups")
    } else if call.caller == .terminal {
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
    /// What the owner is asked to confirm when the command does not come from the app; it ends
    /// the sentence "… is trying to". Nil for a command that gives nothing away and changes
    /// nothing that matters, and for one that asks by itself.
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
    Command(name: nil, what: "one scheduled run (what launchd starts)", run: .backup(.scheduled, readEverything: false)),
    Command(name: "--manual", what: "one run started by hand: ignores the battery condition and the interval",
            run: .backup(.manual, readEverything: false)),
    Command(name: "--full", what: "the same, and reads every folder instead of only those that changed",
            run: .backup(.manual, readEverything: true)),
    Command(name: "serve", what: "answer the app over its connection (what launchd starts for it)", run: .serve),
    Command(name: "status", what: "print the state file",
            run: .plain { _ in (try? Data(contentsOf: Paths.state)) ?? Data("no run yet".utf8) }),

    // What follows is for the app, each printing JSON; from a terminal the owner confirms first.
    Command(name: "snapshots", what: "the snapshots, newest first", confirm: "list your backups",
            run: .configured { _, config in try json(Client(config: config).snapshots()) }),
    Command(name: "list", arguments: "<snapshot> <archive> [<path>]", count: 2...3, what: "one directory",
            confirm: "read the names in your backups",
            run: .configured { call, config in
                let arguments = call.arguments
                return try json(Client(config: config).list(snapshot: arguments[1], archive: arguments[2],
                                                            path: arguments.count > 3 ? arguments[3] : ""))
            }),
    Command(name: "restore", arguments: "<snapshot> <archive> <path> <folder> [keep-both|replace|skip]", count: 4...5,
            what: "restore one item into a folder; keep-both when not said", confirm: "restore files from your backups",
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
            confirm: "read the names in your backups",
            run: .configured { call, config in
                try json(Client(config: config).versions(archive: call.arguments[1], path: call.arguments[2]))
            }),
    Command(name: "index", arguments: "<snapshot> <archive>...", count: 2...Int.max,
            what: "write the names in these archives into the cache, for searching; prints the file",
            confirm: "read the names in your backups",
            run: .configured { call, config in
                try json(["index": Client(config: config).index(snapshot: call.arguments[1],
                                                                archives: Array(call.arguments.dropFirst(2))).path])
            }),
    Command(name: "mount", arguments: "<snapshot> <archive>", count: 2...2,
            what: "show an archive as a read-only folder (needs FUSE-T)", confirm: "open a backup as a folder",
            run: .configured { call, config in
                try json(["mounted": Client(config: config).mount(snapshot: call.arguments[1], archive: call.arguments[2]).path])
            }),
    Command(name: "unmount", what: "unmount every such folder",
            run: .plain { _ in try json(["stillInUse": Client.unmount().map(\.path)]) }),
    Command(name: "sizes", arguments: "<folder>", count: 1...1,
            what: "measure a folder and what is in it, for choosing what to leave out; prints the file",
            run: .plain { call in try json(["sizes": FolderSizes.measure(call.arguments[1]).save().path]) }),
    Command(name: "check", what: #"{"ok":true} when the server accepts repository, namespace and token"#,
            run: .configured { _, config in
                try Client(config: config, needsKey: false).checkConnection()
                return try json(["ok": true])
            }),
    Command(name: "accept",
            what: #"store the settings on standard input, {"config":{…},"token":"…"}, once the server accepts them; without "token" the stored one is tried"#,
            confirm: "change where your backups go",
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
            confirm: "change what is backed up and where to",
            run: .plain { _ in
                try Seal.set(config: Config.load())
                return try json(["ok": true])
            }),
    Command(name: "set-token", what: "store the API token secret from standard input in the Keychain",
            confirm: "replace the API token of your backups",
            run: .plain { call in
                let token = call.input()
                guard !token.isEmpty else { throw Failure(description: "Nothing on standard input.") }
                try Keychain.set(.token, token)
                return try json(["stored": "token"])
            }),
    Command(name: "set-key", what: "store the encryption key file from standard input in the Keychain",
            run: .plain { call in
                try confirmKeyChange(call)
                return try json(KeyStore.importKey(call.input()))
            }),
    Command(name: "create-key", arguments: "[--replace]", count: 0...1,
            what: "make a new encryption key (refused when one exists, unless --replace)",
            run: .plain { call in
                let replacing = call.arguments.contains("--replace")
                guard try replacing || !KeyStore.status().present else { throw Failure(description: "There is an encryption key already.") }
                try confirmKeyChange(call)
                return try json(KeyStore.create(client: Client.executable(clientPath: (try? Config.load())?.clientPath),
                                                replacing: replacing))
            }),
    Command(name: "export-key", arguments: "<file>", count: 1...1,
            what: "write the recovery copy of the key, once the owner has confirmed with Touch ID or the password",
            run: .plain { call in
                try confirmOwner(to: "export the encryption key of your backups")
                try KeyStore.export(to: URL(fileURLWithPath: call.arguments[1]))
                return try json(["exported": call.arguments[1]])
            }),
    Command(name: "paper-key", what: "the key as text to print, once the owner has confirmed with Touch ID or the password",
            run: .plain { _ in
                try confirmOwner(to: "print the encryption key of your backups")
                return try json(["text": KeyStore.paperKey(subject: (try? Config.load())?.backupID ?? "this Mac")])
            }),
    Command(name: "migrate", what: "take over the token and the key that a version before 0.2 stored",
            confirm: "take over the token and the key of an earlier version",
            run: .plain { _ in
                struct Migrated: Encodable { let moved: [String] }
                // The settings are taken over also when the owner turns macOS's question for an
                // old item down; that item then stays where it is, to be asked for again.
                let moved = Result { try Keychain.migrate() }
                try Seal.adopt()
                return try json(Migrated(moved: moved.get().map(\.rawValue)))
            }),
    Command(name: "setup-status", what: "which of configuration, token and key exist",
            run: .plain { _ in
                struct SetupStatus: Encodable { let configured: Bool, token: Bool, key: KeyStore.Status }
                return try json(SetupStatus(configured: (try? Config.load()) != nil, token: try Keychain.get(.token) != nil,
                                            key: try KeyStore.status()))
            }),
    Command(name: "certificate", arguments: "<host> <port>", count: 2...2,
            what: "the server certificate's fingerprint and whether the client takes it without one",
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

func loadConfig() throws -> Config {
    do { return try Config.load() } catch {
        throw Failure(description: "no usable configuration at \(Paths.config.path): \(error.localizedDescription)")
    }
}

/// Answers the app. Every message on a connection comes from a program macOS has checked
/// against the app's signature (`HelperConnection.restrict`), so nothing here asks the owner
/// to confirm, except the commands that do so whoever asks.
final class Helper: NSObject, NSXPCListenerDelegate, HelperProtocol {
    private let log = Logger(subsystem: Identity.bundleID, category: "helper")

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
            guard command.count.contains(arguments.count - 1) else { throw Failure(description: usageText([command])) }
            let call = Call(arguments: arguments, input: { input ?? Data() }, caller: .app)
            let answer: Data
            switch command.run {
            case .backup, .serve:
                throw Failure(description: "A backup is started through launchd, not over this connection.")
            case .plain(let run):
                answer = try run(call)
            case .configured(let run):
                let config = try loadConfig()
                guard Seal.holds(config) else { throw Failure(description: Seal.configChanged) }
                answer = try run(call, config)
            }
            log.notice("\(name, privacy: .public): done")
            reply(answer, nil)
        } catch {
            // The error can name files; the command cannot.
            log.error("\(name, privacy: .public): failed: \(String(describing: error))")
            reply(nil, "\(error)")
        }
    }

    static func serve() -> Never {
        let helper = Helper()
        let listener = NSXPCListener(machServiceName: Identity.helperLabel)
        listener.delegate = helper
        listener.resume()
        withExtendedLifetime(helper) { dispatchMain() }
    }
}

/// Prints what a command made, or its error on standard error.
func finish(_ work: () throws -> Data) -> Never {
    do {
        FileHandle.standardOutput.write(try work() + Data("\n".utf8))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = commands.first(where: { $0.name == arguments.first }) else { usage(commands) }
let fits = command.count.contains(arguments.dropFirst().count)
#if DEBUG
// A development build of the app has no helper job and starts the tool as a program.
let caller: Caller = ProcessInfo.processInfo.environment["PBS_MACKUP_APP"] != nil ? .app : .terminal
#else
let caller = Caller.terminal
#endif
let call = Call(arguments: arguments, input: { FileHandle.standardInput.readDataToEndOfFile() }, caller: caller)

/// What a command asks the owner to confirm when it does not come from the app.
func confirm(_ command: Command) throws {
    if caller == .terminal, let reason = command.confirm { try confirmOwner(to: reason) }
}

/// A missing configuration is said first, whatever else is wrong with the call.
func configuration() -> Config {
    do { return try loadConfig() } catch {
        print("\(error)")
        exit(Runner.Exit.notConfigured.rawValue)
    }
}

switch command.run {
case .serve:
    Helper.serve()
case .backup(let trigger, let readEverything):
    let config = configuration()
    guard fits else { usage([command]) }
    // Whether its configuration is one to go by the run finds out itself, and says so in its record.
    backUp(config, trigger, readEverything: readEverything)
case .plain(let run):
    guard fits else { usage([command]) }
    finish {
        try confirm(command)
        return try run(call)
    }
case .configured(let run):
    let config = configuration()
    guard fits else { usage([command]) }
    finish {
        try confirm(command)
        guard Seal.holds(config) else { throw Failure(description: Seal.configChanged) }
        return try run(call, config)
    }
}
