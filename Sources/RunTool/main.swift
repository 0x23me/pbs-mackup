import Foundation
import PBSMackupKit

// pbs-mackup-run            one scheduled run (what launchd starts)
// pbs-mackup-run --manual   one run started by hand: ignores the battery condition and the interval
// pbs-mackup-run --full     the same, and reads every folder instead of only those that changed
// pbs-mackup-run set-token  store the API token secret from standard input in the Keychain
// pbs-mackup-run set-key    store the encryption key file from standard input in the Keychain
// pbs-mackup-run status     print the state file
// For the app, which leaves the Keychain to this tool; each prints JSON on standard output:
// pbs-mackup-run snapshots                                       the snapshots, newest first
// pbs-mackup-run list <snapshot> <archive> [<path>]              one directory
// pbs-mackup-run restore <snapshot> <archive> <path> <folder> [keep-both|replace|skip]
//                                                            restore one item into a folder; keep-both when not said
// pbs-mackup-run versions <archive> <path>                       the versions of one item, newest first
// pbs-mackup-run index <snapshot> <archive>...                   write the names in these archives into the cache, for searching; prints the file
// pbs-mackup-run mount <snapshot> <archive>                      show an archive as a read-only folder (needs FUSE-T)
// pbs-mackup-run unmount                                         unmount every such folder
// pbs-mackup-run sizes <folder>                                 measure a folder and what is in it, for choosing what to leave out; prints the file
// pbs-mackup-run check                                           {"ok":true} when the server accepts repository, namespace and token
// pbs-mackup-run setup-status                                    which of configuration, token and key exist
// pbs-mackup-run create-key [--replace]                          make a new encryption key (refused when one exists, unless --replace)
// pbs-mackup-run export-key <file>                               write the recovery copy of the key
// pbs-mackup-run paper-key                                       the key as text to print
// pbs-mackup-run certificate <host> <port>                       the server certificate's fingerprint and whether it is publicly trusted

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = Array(CommandLine.arguments.dropFirst())

/// Prints a value as JSON, or its error on standard error.
func report<T: Encodable>(_ work: () throws -> T) -> Never {
    do {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        FileHandle.standardOutput.write(try encoder.encode(work()) + Data("\n".utf8))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
}

func storeFromStandardInput(_ item: Keychain.Item) -> Never {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard !data.isEmpty else { print("nothing on standard input"); exit(1) }
    do { try Keychain.set(item, data); print("stored \(item.rawValue) in the Keychain"); exit(0) }
    catch { print("Keychain: \(error)"); exit(1) }
}

switch arguments.first {
case "set-token": storeFromStandardInput(.token)
case "status":
    print((try? String(contentsOf: Paths.state, encoding: .utf8)) ?? "no run yet")
    exit(0)
case "set-key":
    report { try KeyStore.importKey(FileHandle.standardInput.readDataToEndOfFile()) }
case "setup-status":
    struct SetupStatus: Encodable { let configured: Bool, token: Bool, key: KeyStore.Status }
    report {
        SetupStatus(configured: (try? Config.load()) != nil, token: try Keychain.get(.token) != nil, key: try KeyStore.status())
    }
case "create-key":
    report {
        try KeyStore.create(client: Client.executable(clientPath: (try? Config.load())?.clientPath),
                            replacing: arguments.contains("--replace"))
    }
case "export-key" where arguments.count == 2:
    report { try KeyStore.export(to: URL(fileURLWithPath: arguments[1])); return ["exported": arguments[1]] }
case "certificate" where arguments.count == 3:
    let done = DispatchSemaphore(value: 0)
    var found: ServerCertificate.Info?
    Task { found = await ServerCertificate.fetch(host: arguments[1], port: Int(arguments[2]) ?? 8007); done.signal() }
    done.wait()
    report { () throws -> ServerCertificate.Info in
        guard let found else { throw KeyStore.Failure(description: "\(arguments[1]) is not reachable.") }
        return found
    }
case "paper-key":
    report { ["text": try KeyStore.paperKey(subject: (try? Config.load())?.backupID ?? "this Mac")] }
case "sizes" where arguments.count == 2:
    report { ["sizes": try FolderSizes.measure(arguments[1]).save().path] }
case "unmount":
    report { ["stillInUse": Client.unmount().map(\.path)] }
case nil, "--manual", "--full", "snapshots", "list", "restore", "versions", "index", "mount", "check":
    break
default:
    print("usage: pbs-mackup-run [--manual | --full | set-token | set-key | status | snapshots | list | restore | versions | index | mount | unmount | sizes <folder> | check | setup-status | create-key | export-key <file> | paper-key | certificate <host> <port>]")
    exit(64)
}

let config: Config
do { config = try Config.load() } catch {
    print("no usable configuration at \(Paths.config.path): \(error.localizedDescription)")
    exit(Runner.Exit.notConfigured.rawValue)
}

/// Prints the JSON of a command that talks to the server, or its error on standard error.
func answer<T: Encodable>(_ work: (Client) throws -> T) -> Never {
    report { try work(Client(config: config)) }
}

switch arguments.first {
case "check":
    report { () throws -> [String: Bool] in try Client(config: config, needsKey: false).checkConnection(); return ["ok": true] }
case "snapshots":
    answer { try $0.snapshots() }
case "list" where arguments.count >= 3:
    answer { try $0.list(snapshot: arguments[1], archive: arguments[2], path: arguments.count > 3 ? arguments[3] : "") }
case "restore" where arguments.count == 5 || arguments.count == 6:
    struct Restored: Encodable { let restored: String? }
    guard let conflict = Client.Conflict(rawValue: arguments.count == 6 ? arguments[5] : "keep-both") else {
        print("the last argument is keep-both, replace or skip")
        exit(64)
    }
    answer { Restored(restored: try $0.restore(snapshot: arguments[1], archive: arguments[2], path: arguments[3],
                                               into: URL(fileURLWithPath: arguments[4]), conflict: conflict)?.path) }
case "versions" where arguments.count == 3:
    answer { try $0.versions(archive: arguments[1], path: arguments[2]) }
case "index" where arguments.count >= 3:
    answer { ["index": try $0.index(snapshot: arguments[1], archives: Array(arguments.dropFirst(2))).path] }
case "mount" where arguments.count == 3:
    answer { ["mounted": try $0.mount(snapshot: arguments[1], archive: arguments[2]).path] }
case "list", "restore", "versions", "index", "mount":
    print("usage: pbs-mackup-run list <snapshot> <archive> [<path>] | restore <snapshot> <archive> <path> <folder> [keep-both|replace|skip] | versions <archive> <path> | index <snapshot> <archive>... | mount <snapshot> <archive>")
    exit(64)
default:
    break
}

// The app leaves a marker before it asks launchd to start the job.
var trigger: Trigger = arguments.first == "--manual" || arguments.first == "--full" ? .manual : .scheduled
if FileManager.default.fileExists(atPath: Paths.manualRequest.path) {
    try? FileManager.default.removeItem(at: Paths.manualRequest)
    trigger = .manual
}

let runner = Runner(config: config, trigger: trigger, readEverything: arguments.first == "--full")
var sources: [DispatchSourceSignal] = []
for number in [SIGTERM, SIGINT] {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
    source.setEventHandler { runner.cancel() }
    source.resume()
    sources.append(source)
}
exit(runner.run().rawValue)
