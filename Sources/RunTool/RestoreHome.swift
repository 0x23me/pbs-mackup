import Darwin
import Foundation
import PBSMackupKit

// `restore-home`: the whole home folder of a user back from a backup, on a Mac that was set up
// anew. Run with sudo from the account of another administrator; README "After losing the Mac".

let restoreHomeArguments = "<user> <repository> <key file> [--ns <namespace>] [--from <backup id> | --snapshot <snapshot>] "
    + "[--archive <folder>.pxar] [--fingerprint <fingerprint>] [--yes]"

func restoreHome(_ call: Call) throws -> Data {
    guard call.caller == .terminal else { throw Failure(description: "restore-home is run from a terminal, not by the app.") }
    guard geteuid() == 0 else {
        throw Failure(description: "restore-home needs root: run it with sudo, from the account of another administrator.")
    }
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
    let restored = URL(fileURLWithPath: account.home.path + ".restored")
    let aside = URL(fileURLWithPath: account.home.path + ".before-restore")
    for item in [restored, aside] where FileManager.default.fileExists(atPath: item.path) {
        throw Failure(description: "\(item.path) is there already, from an earlier try. Move it out of the way first.")
    }
    if let size = snapshot.size, let free = HomeRestore.freeBytes(at: URL(fileURLWithPath: "/Users")), free < size + size / 10 {
        throw Failure(description: "The snapshot takes \(bytes(size)), and the disk has \(bytes(free)) free.")
    }

    print("""
        Restoring \(archive) from \(snapshot.name)\(snapshot.size.map { " (\(bytes($0)))" } ?? "")
        into \(account.home.path), the home folder of \(account.name) (uid \(account.uid)).
        The folder that is there now is kept as \(aside.path).
        """)
    if !yes {
        print("Go ahead? [y/N] ", terminator: "")
        guard let answer = readLine(), answer.lowercased().hasPrefix("y") else { return Data("Nothing was changed.".utf8) }
    }

    try HomeRestore.restore(client, snapshot: snapshot.name, archive: archive, into: restored) { FileHandle.standardOutput.write($0) }

    let notes = HomeRestore.adapt(restored, to: account)

    try HomeRestore.swap(home: account.home, restored: restored, aside: aside)
    return Data((notes + ["""
        Done. \(account.home.path) is the restored home folder.
        Restart, log in as \(account.name) with the password the old Mac had (it opens the old login keychain),
        and give PBS Mackup Full Disk Access again. Once everything is there, delete \(aside.path) and this administrator.
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
