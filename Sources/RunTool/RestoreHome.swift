import Darwin
import Foundation
import PBSMackupKit

// `restore-home`: the whole home folder of a user back from a backup, on a Mac that was set up
// anew. Run with sudo from the account of another administrator; README "After losing the Mac".
// That it runs as root, and not for the app, is what its entry in `commands` says.

let restoreHomeArguments = "<user> <repository> <key file> [--ns <namespace>] [--from <backup id> | --snapshot <snapshot>] "
    + "[--archive <folder>.pxar] [--fingerprint <fingerprint>] [--yes]"

func restoreHome(_ call: Call) throws -> Data {
    var positional: [String] = [], options: [String: String] = [:], yes = false
    var rest = call.arguments.dropFirst()
    while let argument = rest.popFirst() {
        switch argument {
        case "--yes": yes = true
        case "--ns", "--from", "--snapshot", "--archive", "--fingerprint":
            guard let value = rest.popFirst() else { throw Failure(description: "\(argument) needs a value.") }
            options[argument] = value
        default:
            guard !argument.hasPrefix("-") else { throw Failure(description: "restore-home has no option \(argument).") }
            positional.append(argument)
        }
    }
    guard positional.count == 3 else { throw Failure(description: "usage: pbs-mackup-run restore-home \(restoreHomeArguments)") }
    if options["--from"] != nil, options["--snapshot"] != nil { throw Failure(description: "Either --from or --snapshot, not both.") }

    let account = try HomeRestore.account(positional[0])
    if let sudoUID = ProcessInfo.processInfo.environment["SUDO_UID"], sudoUID == String(account.uid) {
        throw Failure(description: "You are logged in as \(account.name). Log in as another administrator and run it from there.")
    }
    guard !HomeRestore.hasPrograms(uid: account.uid) else {
        throw Failure(description: "\(account.name) is logged in or still has programs running. Log \(account.name) out "
            + "(Log Out, not only switching users), or restart and log in only as this administrator.")
    }

    let keyFile = URL(fileURLWithPath: (positional[2] as NSString).expandingTildeInPath)
    guard let key = try? Data(contentsOf: keyFile) else { throw Failure(description: "The key file \(keyFile.path) cannot be read.") }
    let passphrase = KeyStore.isLocked(key) ? try secret("Passphrase of the key file: ") : nil
    let token = try secret("API token secret for \(positional[1]): ")

    var config = Config(repository: positional[1], namespace: options["--ns"] ?? "", backupID: "", sources: [])
    config.fingerprint = options["--fingerprint"]
    let client = Client(config: config, token: Data(token.utf8), key: key, keyPassphrase: passphrase.map { Data($0.utf8) })

    let archive = options["--archive"] ?? Config.archiveName(for: account.home.path)
    let snapshot = try HomeRestore.choose(from: client.snapshots(group: nil), archive: archive,
                                          requested: options["--snapshot"], group: options["--from"])
    // The user is logged out now and can log in while the restore runs: it works in a folder
    // only root can enter, as the restore daemon does.
    let places = HomeRestore.Places(home: account.home)
    try HomeRestore.preflight(places, size: snapshot.size)

    print("""
        Restoring \(archive) from \(snapshot.name)\(snapshot.size.map { " (\(bytes($0)))" } ?? "")
        into \(account.home.path), the home folder of \(account.name) (uid \(account.uid)).
        The folder that is there now is kept as \(places.aside.path).
        """)
    if !yes {
        print("Go ahead? [y/N] ", terminator: "")
        guard let answer = readLine(), answer.lowercased().hasPrefix("y") else { return Data("Nothing was changed.".utf8) }
    }

    try HomeRestore.restore(client, snapshot: snapshot.name, archive: archive, into: places) { FileHandle.standardOutput.write($0) }

    let notes = HomeRestore.adapt(places.restored, to: account)

    try HomeRestore.swap(places)
    return Data((notes + ["""
        Done. \(account.home.path) is the restored home folder.
        Restart, log in as \(account.name) with the password the old Mac had (it opens the old login keychain),
        and give PBS Mackup Full Disk Access again. Enter the API token in its Settings and import the recovery copy
        of the key: they stayed in the Keychain of the old Mac. Once everything is there, delete \(places.aside.path)
        and this administrator.
        """]).joined(separator: "\n").utf8)
}

/// Asks for a secret at the terminal without showing it; reads a line of standard input when
/// there is no terminal.
func secret(_ prompt: String) throws -> String {
    var buffer = [CChar](repeating: 0, count: 1024)
    defer { memset_s(&buffer, buffer.count, 0, buffer.count) }
    if isatty(STDIN_FILENO) == 1 {
        guard readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else { throw Failure(description: "Nothing was entered.") }
        let value = String(cString: buffer)
        guard !value.isEmpty else { throw Failure(description: "Nothing was entered.") }
        return value
    }
    guard let line = readLine(), !line.isEmpty else { throw Failure(description: "Standard input gave no \(prompt.dropLast(2).lowercased()).") }
    return line
}

func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
