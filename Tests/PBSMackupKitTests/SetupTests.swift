import Foundation
import Testing
@testable import PBSMackupKit

// What setting up needs: the key and its recovery copies, the server's certificate, the folders
// that can be backed up, and the run tool's commands for them. Nothing here needs the real
// client, a server or the Keychain.

private let plainKey = Data(#"{"kdf":null,"created":"2026-01-02T03:04:05+01:00","data":"bm90IGEgcmVhbCBrZXk=","fingerprint":"aa:bb:cc"}"#.utf8)
/// As `proxmox-backup-client key create --kdf scrypt` writes a key: locked with a passphrase.
private let lockedKey = Data(#"{"kdf":{"Scrypt":{"n":65536,"r":8,"p":1,"salt":"c2FsdA=="}},"created":"2026-01-02T03:04:05+01:00","data":"bm90IGEgcmVhbCBrZXk=","fingerprint":"aa:bb:cc"}"#.utf8)

/// Made with `proxmox-backup-client key create <file> --kdf scrypt` and `--kdf pbkdf2`, both
/// with the passphrase “correct horse”, and the fingerprint of each.
private let realLockedKeys = [
    (Data(#"{"kdf":{"Scrypt":{"n":65536,"r":8,"p":1,"salt":"b86TUKqKNDQojwtkQH8zwqdwIzq4uqNzE2C9i77ywK4="}},"created":"2026-11-14T01:47:34+01:00","modified":"2026-11-14T01:47:34+01:00","data":"SU4/LxXv/Vu6/OV5JgcCyTSs/eIMF2P24eZ3iI1HX3GlxiUkqDnANrcreIUBXGhYHmKRewgMZEZu3BOwpOb2hA==","fingerprint":"f4:a4:79:02:4d:4b:ae:c8:7e:5e:a3:f9:86:cf:e1:22:f4:f1:cd:eb:09:2c:81:80:de:eb:72:27:8e:92:cb:61"}"#.utf8),
     "f4:a4:79:02:4d:4b:ae:c8:7e:5e:a3:f9:86:cf:e1:22:f4:f1:cd:eb:09:2c:81:80:de:eb:72:27:8e:92:cb:61"),
    (Data(#"{"kdf":{"PBKDF2":{"iter":65535,"salt":"Rwp8++mRZpty2n7XJiRpQ8IbfDmNhtSFaPIX7hngEf8="}},"created":"2026-11-14T01:47:34+01:00","modified":"2026-11-14T01:47:34+01:00","data":"bI8dwo+UIKAR3T5PLgEBIGIMJ7obVLeQnrhqgWESlYlVcd3UyJRpK9zoUiLglHDMkugMF9XXQPPhJTbKnMgPug==","fingerprint":"6c:c0:88:63:f9:79:9e:e3:4e:7f:0c:ca:28:63:db:39:bd:9b:a9:74:32:41:49:c1:62:90:bc:16:d7:bd:8f:c3"}"#.utf8),
     "6c:c0:88:63:f9:79:9e:e3:4e:7f:0c:ca:28:63:db:39:bd:9b:a9:74:32:41:49:c1:62:90:bc:16:d7:bd:8f:c3"),
]

/// Stands in for `key change-passphrase <file> --kdf none`: notes its arguments, environment and
/// how open the folder is, wants a terminal on standard input as the client does, and takes
/// “correct horse” from the descriptor in PBS_ENCRYPTION_PASSWORD_FD, which unlocks the key.
private let unlockingClient = """
    #!/bin/sh
    noted="$(/usr/bin/dirname "$0")"
    printf '%s\\n' "$@" > "$noted/client-arguments"
    env > "$noted/client-environment"
    /usr/bin/stat -f %Lp "$(/usr/bin/dirname "$3")" > "$noted/client-folder"
    [ -t 0 ] || { echo "Error: unable to change passphrase - no tty" >&2; exit 255; }
    [ "$1 $2 $4 $5" = "key change-passphrase --kdf none" ] || exit 2
    read -r passphrase <&"$PBS_ENCRYPTION_PASSWORD_FD"
    if [ "$passphrase" != "correct horse" ]; then
        echo "Error: Unable to decrypt key (wrong password?) - error:1C800066:Provider routines::cipher operation failed" >&2
        exit 255
    fi
    umask 077
    printf '%s' '\(String(decoding: plainKey, as: UTF8.self))' > "$3"

    """

/// Puts the stand-in for unlocking a key into `home`.
private func unlockingClient(in home: URL) throws -> URL {
    let client = home.appendingPathComponent("proxmox-backup-client")
    try Data(unlockingClient.utf8).write(to: client)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: client.path)
    return client
}

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
private func runTool(_ arguments: [String], home: URL, input: Data = Data(),
                     environment: [String: String] = [:]) throws -> (status: Int32, output: String, errors: String) {
    let process = Process(), output = Pipe(), errors = Pipe(), standardInput = Pipe()
    process.executableURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".build/debug/pbs-mackup-run")
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.merging(["PBS_MACKUP_HOME": home.path]) { $1 }.merging(environment) { $1 }
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
        #expect(KeyStore.isLocked(lockedKey) && !KeyStore.isLocked(plainKey) && !KeyStore.isLocked(Data("not a key".utf8)))
        let refusal = #expect(throws: KeyStore.Failure.self) { try KeyStore.importKey(lockedKey) }
        // The sentence says where such a key file is taken.
        #expect(refusal?.description.contains("asks for the passphrase") == true)
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

@Test func aKeyLockedWithAPassphraseIsStoredWithoutIt() throws {
    try withPrivateHome { home in
        let client = try unlockingClient(in: home)
        func noted(_ what: String) -> String { (try? String(contentsOf: home.appendingPathComponent("client-\(what)"), encoding: .utf8)) ?? "" }
        func leftOver() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: Paths.guarded.path).filter { $0.hasPrefix("key-") }
        }

        // A wrong passphrase stores nothing and says so, with the hint the file has.
        let wrong = #expect(throws: KeyStore.Failure.self) { try KeyStore.importKey(lockedKey, passphrase: "wrong horse", client: client) }
        #expect(wrong?.description == "The passphrase is wrong.")
        #expect(try !KeyStore.status().present)
        let hinted = Data(String(decoding: lockedKey, as: UTF8.self).replacingOccurrences(of: "}},", with: #"}},"hint":"the stable","#).utf8)
        let hint = #expect(throws: KeyStore.Failure.self) { try KeyStore.importKey(hinted, passphrase: "wrong horse", client: client) }
        #expect(hint?.description == "The passphrase is wrong. The key file's hint: the stable")
        // What the client would not take is refused before it starts.
        try FileManager.default.removeItem(at: home.appendingPathComponent("client-arguments"))
        #expect(throws: KeyStore.Failure.self) { try KeyStore.importKey(lockedKey, passphrase: "four", client: client) }
        #expect(throws: KeyStore.Failure.self) { try KeyStore.importKey(lockedKey, passphrase: "correct\nhorse", client: client) }
        #expect(noted("arguments").isEmpty)

        // The right one stores the unlocked key, as an import of that would.
        #expect(try KeyStore.importKey(lockedKey, passphrase: "correct horse", client: client).fingerprint == "aa:bb:cc")
        #expect(try Keychain.get(.encryptionKey) == plainKey)
        #expect(try KeyStore.status().foreign == false)
        // The passphrase was neither in the client's arguments nor in its environment, and the
        // key passed through a folder only the owner can enter, which is gone.
        #expect(!noted("arguments").isEmpty && !noted("arguments").contains("horse"))
        #expect(!noted("environment").isEmpty && !noted("environment").contains("horse"))
        #expect(noted("environment").contains("PBS_ENCRYPTION_PASSWORD_FD=3\n"))
        #expect(noted("folder") == "700\n")
        #expect(try leftOver() == [])

        // A paper key, with its marker lines and the text around them; and a key without a
        // passphrase, which needs none.
        try Keychain.set(.encryptionKey, Data("another key".utf8))
        let paper = "Encryption key\n\n-----BEGIN PROXMOX BACKUP KEY-----\n\(String(decoding: lockedKey, as: UTF8.self))\n-----END PROXMOX BACKUP KEY-----\n"
        #expect(KeyStore.isLocked(Data(paper.utf8)))
        #expect(try KeyStore.importKey(Data(paper.utf8), passphrase: "correct horse", client: client).fingerprint == "aa:bb:cc")
        #expect(try Keychain.get(.encryptionKey) == plainKey)
        let plain = Data(#"{"kdf":null,"data":"bm90IGEgcmVhbCBrZXk=","fingerprint":"dd:ee:ff"}"#.utf8)
        #expect(try KeyStore.importKey(plain, passphrase: "not asked", client: client).fingerprint == "dd:ee:ff")
        #expect(try leftOver() == [])
    }
}

/// The client's own `key change-passphrase`, which `KeyStore.importKey(_:passphrase:client:)` is
/// written for. Runs with the real client when PBS_MACKUP_CLIENT names one.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PBS_MACKUP_CLIENT"].map(FileManager.default.isExecutableFile) == true))
func theRealClientTakesThePassphraseOffAKey() throws {
    let client = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["PBS_MACKUP_CLIENT"]))
    try withPrivateHome { _ in
        for (locked, fingerprint) in realLockedKeys {
            try Keychain.set(.encryptionKey, plainKey)
            let wrong = #expect(throws: KeyStore.Failure.self) { try KeyStore.importKey(locked, passphrase: "wrong horse", client: client) }
            #expect(wrong?.description == "The passphrase is wrong.")
            #expect(try Keychain.get(.encryptionKey) == plainKey)       // the key there stays
            #expect(try KeyStore.importKey(locked, passphrase: "correct horse", client: client).fingerprint == fingerprint)
            struct Unlocked: Decodable { let kdf: String?, data: String, created: String }
            let stored = try JSONDecoder().decode(Unlocked.self, from: try #require(try Keychain.get(.encryptionKey)))
            #expect(stored.kdf == nil && Data(base64Encoded: stored.data)?.count == 32)
            #expect(stored.created == "2026-11-14T01:47:34+01:00")      // the key's own date stays
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: Paths.guarded.path).filter { $0.hasPrefix("key-") } == [])
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
        // `unlock-key` takes it with its passphrase, and says when that is wrong.
        let client = try unlockingClient(in: home)
        func unlock(_ passphrase: String) throws -> (status: Int32, output: String, errors: String) {
            let input = try JSONEncoder().encode(["key": String(decoding: lockedKey, as: UTF8.self), "passphrase": passphrase])
            return try runTool(["unlock-key"], home: home, input: input, environment: ["PBS_MACKUP_CLIENT": client.path])
        }
        #expect(try unlock("wrong horse").errors == "The passphrase is wrong.\n")
        #expect(try runTool(["unlock-key"], home: home, input: lockedKey).errors.contains(#"{"key":"…","passphrase":"…"}"#))
        #expect(try unlock("correct horse").output.contains(#""fingerprint":"aa:bb:cc""#))
        #expect(try Keychain.get(.encryptionKey) == plainKey)
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
