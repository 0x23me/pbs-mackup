import Foundation
import Testing
@testable import PBSMackupKit

// What the settings window asks of the run tool when the connection is tested: `accept` stores
// the configuration and the token only once the server took them. A script stands in for the
// client and the server; nothing here needs the real client, a server or the Keychain.

/// Notes the token it was given, on descriptor 3 as the run tool hands it over, and answers
/// like a server that knows the tokens that begin with `right`.
private let script = #"""
    #!/bin/sh
    token="$(cat <&3)"
    printf '%s' "$token" > "$PBS_MACKUP_HOME/client-token"
    case "$token" in
        right*) echo "[]" ;;
        *) echo "Error: permission check failed" >&2; exit 255 ;;
    esac
    """#

/// Starts the pbs-mackup-run of the debug build in a private home. Only ever that build: it
/// keeps its secrets under PBS_MACKUP_HOME and runs the client the configuration names.
private func runTool(_ arguments: [String], home: URL, input: Data) throws -> (status: Int32, output: String, errors: String) {
    let process = Process(), output = Pipe(), errors = Pipe(), standardInput = Pipe()
    process.executableURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".build/debug/pbs-mackup-run")
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.merging(["PBS_MACKUP_HOME": home.path]) { $1 }
    process.standardOutput = output
    process.standardError = errors
    process.standardInput = standardInput
    try process.run()
    standardInput.fileHandleForWriting.write(input)
    try standardInput.fileHandleForWriting.close()
    let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let complaints = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return (process.terminationStatus, printed, complaints)
}

extension PrivateHomeTests {
@Test func theRunToolStoresSettingsOnlyOnceTheServerAcceptedThem() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("pbs-mackup-settings-\(UUID().uuidString)")
    let client = home.appendingPathComponent("bin/proxmox-backup-client")
    try FileManager.default.createDirectory(at: client.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(script.utf8).write(to: client)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: client.path)
    setenv("PBS_MACKUP_HOME", home.path, 1)         // for Keychain and Config in this process
    defer { unsetenv("PBS_MACKUP_HOME"); try? FileManager.default.removeItem(at: home) }
    // Nothing listens on port 1, should the real client ever be asked.
    let config = Config(repository: "test@pbs!mac@127.0.0.1:1:store", namespace: "test", backupID: "test-mac",
                        sources: ["/Users/me/Documents"], excludes: ["*.tmp"], clientPath: client.path)
    /// The token the stand-in was last started with; nil when it never was.
    var tried: String? { try? String(contentsOf: home.appendingPathComponent("client-token"), encoding: .utf8) }
    /// Hands the settings over as the app does: the configuration and, when one was typed, the token.
    func accept(_ config: Config, token: String? = nil) throws -> (status: Int32, output: String, errors: String) {
        let config = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        let token = token.map { #","token":"\#($0)""# } ?? ""
        return try runTool(["accept"], home: home, input: Data(#"{"config":\#(config)\#(token)}"#.utf8))
    }

    // What is not settings is an error, and the client is not even started.
    for nonsense in ["", "not json", #"{"token":"right-token"}"#, #"{"config":{"repository":"x"},"token":"right-token"}"#] {
        let refused = try runTool(["accept"], home: home, input: Data(nonsense.utf8))
        #expect(refused.status == 1, "\(nonsense)")
        #expect(refused.errors.contains(#"Standard input should be {"config":{…},"token":"…"}"#), "\(refused.errors)")
    }
    #expect(tried == nil)
    #expect(try Keychain.get(.token) == nil)
    #expect((try? Config.load()) == nil)

    // A token the server turns down, and no token where none is stored: nothing is stored.
    let wrong = try accept(config, token: "wrong-token")
    #expect(wrong.status == 1)
    #expect(wrong.errors == "permission check failed\n")
    #expect(tried == "wrong-token")                 // it was the candidate that was tried
    #expect(try accept(config).errors == "The API token is not in the Keychain.\n")
    #expect(try Keychain.get(.token) == nil)
    #expect((try? Config.load()) == nil)

    // Accepted: the token and the configuration are stored.
    let accepted = try accept(config, token: "right-token")
    #expect(accepted.status == 0, "\(accepted.errors)")
    #expect(accepted.output == "{\"ok\":true}\n")
    #expect(try Keychain.get(.token) == Data("right-token".utf8))
    #expect(try Config.load() == config)

    // A change the server refuses leaves both as they were.
    var changed = config
    changed.namespace = "other"
    #expect(try accept(changed, token: "wrong-again").status == 1)
    #expect(tried == "wrong-again")
    #expect(try Keychain.get(.token) == Data("right-token".utf8))
    #expect(try Config.load() == config)

    // Without a token the stored one is tried, and stays.
    #expect(try accept(changed).status == 0)
    #expect(tried == "right-token")
    #expect(try Keychain.get(.token) == Data("right-token".utf8))
    #expect(try Config.load() == changed)
}
}
