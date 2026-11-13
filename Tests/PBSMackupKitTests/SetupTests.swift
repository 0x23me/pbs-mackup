import Foundation
import Testing
@testable import PBSMackupKit

// What setting up needs: the key and its recovery copies, the server's certificate, the folders
// that can be backed up, and the run tool's commands for them. Nothing here needs the real
// client, a server or the Keychain.

private let plainKey = Data(#"{"kdf":null,"created":"2026-01-02T03:04:05+01:00","data":"bm90IGEgcmVhbCBrZXk=","fingerprint":"aa:bb:cc"}"#.utf8)
/// As `proxmox-backup-client key create --kdf scrypt` writes a key: locked with a passphrase.
private let lockedKey = Data(#"{"kdf":{"Scrypt":{"n":65536,"r":8,"p":1,"salt":"c2FsdA=="}},"created":"2026-01-02T03:04:05+01:00","data":"bm90IGEgcmVhbCBrZXk=","fingerprint":"aa:bb:cc"}"#.utf8)

/// A home of its own for one test: PBS_MACKUP_HOME names it while `body` runs, so the key is a
/// file in it instead of a Keychain item.
private func withPrivateHome(_ body: (URL) throws -> Void) throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("pbs-mackup-setup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    setenv("PBS_MACKUP_HOME", home.path, 1)
    defer { unsetenv("PBS_MACKUP_HOME"); try? FileManager.default.removeItem(at: home) }
    try body(home)
}

/// Starts the pbs-mackup-run of the debug build in a private home. Only ever that build: it
/// keeps its secrets under PBS_MACKUP_HOME and asks nobody to confirm with Touch ID.
private func runTool(_ arguments: [String], home: URL, input: Data = Data()) throws -> (status: Int32, output: String, errors: String) {
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

private func mode(of file: URL) throws -> Int? {
    try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
}

@Test func archiveNamesAreWhatTheClientTakes() {
    // The client takes letters, digits, - and _ before ".pxar", and reads a leading - as an option.
    #expect(Config.archiveName(for: "/Users/me/-x") == "_x.pxar")
    #expect(Config.archiveName(for: "/Users/me/.ssh") == "_ssh.pxar")
    #expect(Config.archiveName(for: "/Users/me/Photos Library.photoslibrary") == "Photos_Library_photoslibrary.pxar")
    #expect(Config.archiveName(for: "/Users/me/a-b_c") == "a-b_c.pxar")
    #expect(Config.archiveName(for: "/Users/me/Fotos été") == "Fotos__t_.pxar")
}

@Test func aFolderThatARunCouldNotReadIsNotAdded() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pbs-mackup-folders-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    func path(_ name: String) -> String { root.appendingPathComponent(name).path }
    for folder in ["one/Downloads", "two/Downloads", "three/downloads", "two/Fotos é", "two/Fotos ü"] {
        try FileManager.default.createDirectory(atPath: path(folder), withIntermediateDirectories: true)
    }
    try Data("x".utf8).write(to: root.appendingPathComponent("note.txt"))
    try FileManager.default.createSymbolicLink(atPath: path("link"), withDestinationPath: path("one/Downloads"))

    #expect(Config.objection(toAdding: path("one/Downloads"), to: []) == nil)
    #expect(Config.objection(toAdding: path("two/Fotos é"), to: [path("one/Downloads")]) == nil)
    // Two folders of one name would be two archives of one name, which the client refuses.
    #expect(Config.objection(toAdding: path("two/Downloads"), to: [path("one/Downloads")])?.contains("same name") == true)
    #expect(Config.objection(toAdding: path("two/Fotos ü"), to: [path("two/Fotos é")])?.contains("same name") == true)
    #expect(Config.objection(toAdding: path("three/downloads"), to: [path("one/Downloads")])?.contains("same name") == true)
    // A run names the archive after the folder a link leads to.
    #expect(Config.objection(toAdding: path("link"), to: [path("two/Downloads")])?.contains("same name") == true)
    #expect(Config.objection(toAdding: path("link"), to: [path("one/Downloads")])?.contains("already in the list") == true)
    #expect(Config.objection(toAdding: path("note.txt"), to: [])?.contains("not a folder") == true)
    #expect(Config.objection(toAdding: path("missing"), to: [])?.contains("not a folder") == true)
    // /dev is a folder, but not one on the disk a run takes its snapshot of.
    #expect(Config.objection(toAdding: "/dev", to: [])?.contains("another disk") == true)
}

@Test func aCertificateIsTrustedOnlyThroughTheRootsTheClientHas() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pbs-mackup-roots-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    func path(_ name: String) -> String { folder.appendingPathComponent(name).path }
    try Data("""
        [req]
        distinguished_name = name
        [name]
        [root]
        basicConstraints = critical,CA:TRUE
        keyUsage = critical,keyCertSign
        [server]
        basicConstraints = CA:FALSE
        subjectAltName = DNS:pbs.test
        extendedKeyUsage = serverAuth
        """.utf8).write(to: folder.appendingPathComponent("openssl.cnf"))
    // A root of the owner's own, as a home server has one, and a certificate for pbs.test from it.
    for arguments in [
        ["req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes", "-days", "30", "-config", path("openssl.cnf"),
         "-extensions", "root", "-subj", "/CN=pbs-mackup test root", "-keyout", path("root.key"), "-out", path("root.pem")],
        ["req", "-new", "-newkey", "rsa:2048", "-nodes", "-config", path("openssl.cnf"), "-subj", "/CN=pbs.test",
         "-keyout", path("server.key"), "-out", path("server.csr")],
        ["x509", "-req", "-sha256", "-days", "30", "-in", path("server.csr"), "-CA", path("root.pem"), "-CAkey", path("root.key"),
         "-CAcreateserial", "-extfile", path("openssl.cnf"), "-extensions", "server", "-out", path("server.pem")],
    ] {
        let made = tool("/usr/bin/openssl", arguments)
        try #require(made.status == 0, "\(made.output)")
    }
    let server = try #require(ServerCertificate.certificates(inPEMFile: path("server.pem")).first)
    func trust(for host: String) throws -> SecTrust {
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(server, SecPolicyCreateSSL(true, host as CFString), &trust) == errSecSuccess)
        return try #require(trust)
    }

    #expect(ServerCertificate.accepted(try trust(for: "pbs.test"), roots: path("root.pem")))       // the client has this root,
    #expect(!ServerCertificate.accepted(try trust(for: "other.test"), roots: path("root.pem")))    // but not under another name
    // Not with the roots macOS ships, which are all the client gets, and not without any.
    #expect(ServerCertificate.certificates(inPEMFile: ServerCertificate.roots).count > 50)
    #expect(!ServerCertificate.accepted(try trust(for: "pbs.test")))
    #expect(!ServerCertificate.accepted(try trust(for: "pbs.test"), roots: path("missing.pem")))
}

extension PrivateHomeTests {
@Test func aKeyLockedWithAPassphraseIsNotTaken() throws {
    try withPrivateHome { _ in
        let refusal = #expect(throws: KeyStore.Failure.self) { try KeyStore.importKey(lockedKey) }
        // The sentence says how to get a key file that can be imported.
        #expect(refusal?.description.contains("key change-passphrase <copy> --kdf none") == true)
        let stored = try KeyStore.status()
        #expect(!stored.present)
        #expect(try KeyStore.importKey(plainKey).fingerprint == "aa:bb:cc")
        // A key file that does not have the field at all.
        #expect(try KeyStore.importKey(Data(#"{"data":"bm90IGEgcmVhbCBrZXk=","fingerprint":"dd:ee:ff"}"#.utf8)).fingerprint == "dd:ee:ff")
    }
}

@Test func theRecoveryFileReplacesAnOlderOneAndIsTheOwnersAlone() throws {
    try withPrivateHome { home in
        _ = try KeyStore.importKey(plainKey)
        let folder = home.appendingPathComponent("stick")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent("recovery.json")
        try Data("an older copy".utf8).write(to: copy)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: copy.path)

        try KeyStore.export(to: copy)
        #expect(try Data(contentsOf: copy) == plainKey)
        #expect(try mode(of: copy) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["recovery.json"])   // nothing left beside it

        // Where it cannot be written, nothing is left behind either.
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("taken/by a folder"), withIntermediateDirectories: true)
        #expect(throws: KeyStore.Failure.self) { try KeyStore.export(to: folder.appendingPathComponent("taken")) }
        #expect(throws: KeyStore.Failure.self) { try KeyStore.export(to: folder.appendingPathComponent("missing/recovery.json")) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["recovery.json", "taken"])
    }
}

@Test func aNewKeyPassesThroughAFolderOnlyTheOwnerCanEnter() throws {
    try withPrivateHome { home in
        // Stands in for `key create <file> --kdf none`: notes how open the folder is, then writes a key there.
        let client = home.appendingPathComponent("proxmox-backup-client")
        try Data("""
            #!/bin/sh
            /usr/bin/stat -f %Lp "$(/usr/bin/dirname "$3")" > "$0.folder"
            umask 077
            printf '%s' '\(String(decoding: plainKey, as: UTF8.self))' > "$3"

            """.utf8).write(to: client)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: client.path)

        #expect(try KeyStore.create(client: client).fingerprint == "aa:bb:cc")
        #expect(try String(contentsOfFile: client.path + ".folder", encoding: .utf8) == "700\n")
        #expect(try Keychain.get(.encryptionKey) == plainKey)
        #expect(try FileManager.default.contentsOfDirectory(atPath: Paths.cache.path).filter { $0.hasPrefix("key-") } == [])
        #expect(throws: KeyStore.Failure.self) { try KeyStore.create(client: client) }       // there is one already
        #expect(try KeyStore.create(client: client, replacing: true).present)
    }
}

@Test func theRunToolTakesItsCommandsFromOneList() throws {
    try withPrivateHome { home in
        let unknown = try runTool(["no-such-command"], home: home)
        #expect(unknown.status == 64)
        for line in ["pbs-mackup-run --manual\n", "pbs-mackup-run export-key <file>\n", "pbs-mackup-run certificate <host> <port>\n"] {
            #expect(unknown.output.contains(line), "missing \(line)")
        }
        // A command without what it needs is told how it alone is called.
        let short = try runTool(["export-key"], home: home)
        #expect(short.status == 64)
        #expect(short.output.contains("pbs-mackup-run export-key <file>\n") && !short.output.contains("paper-key"))
        #expect(try runTool(["restore", "snapshot", "archive"], home: home).status == Runner.Exit.notConfigured.rawValue)

        // Without a configuration a run stops before it does anything; other commands do not need one.
        for run in [[], ["--manual"], ["--full"], ["snapshots"]] {
            let stopped = try runTool(run, home: home)
            #expect(stopped.status == Runner.Exit.notConfigured.rawValue)
            #expect(stopped.output.contains("no usable configuration"))
        }
        #expect(try runTool(["status"], home: home).output == "no run yet\n")
        let status = try runTool(["setup-status"], home: home)
        #expect(status.status == 0)
        #expect(status.output.contains(#""configured":false"#) && status.output.contains(#""present":false"#))
    }
}

@Test func theRunToolStoresAKeyAndHandsOutItsRecoveryCopies() throws {
    try withPrivateHome { home in
        let locked = try runTool(["set-key"], home: home, input: lockedKey)
        #expect(locked.status == 1)
        #expect(locked.errors.contains("locked with a passphrase"))
        #expect(try runTool(["set-key"], home: home, input: plainKey).output.contains(#""fingerprint":"aa:bb:cc""#))

        let copy = home.appendingPathComponent("recovery.json")
        #expect(try runTool(["export-key", copy.path], home: home).status == 0)
        #expect(try Data(contentsOf: copy) == plainKey)
        #expect(try mode(of: copy) == 0o600)
        let paper = try runTool(["paper-key"], home: home)
        #expect(paper.status == 0)
        #expect(paper.output.contains("-----BEGIN PROXMOX BACKUP KEY-----"))
    }
}
}
