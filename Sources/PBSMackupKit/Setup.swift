import CryptoKit
import Foundation

/// The encryption key in the Keychain: creating, importing and the recovery copies. Only the
/// run tool calls these, because it owns the Keychain items.
public enum KeyStore {
    public struct Status: Codable, Equatable {
        public let present: Bool
        public let fingerprint: String?
        public let created: String?
        /// True for a key that neither the app nor the run tool put into the Keychain. A run
        /// does not use such a key; see `Seal`.
        public var foreign = false
    }

    public typealias Failure = PBSMackupKit.Failure

    private struct KeyFile: Decodable {
        /// Whatever a field holds, where only its being there matters.
        struct Anything: Decodable { init(from decoder: Decoder) throws {} }

        let data: String
        let fingerprint: String?
        let created: String?
        /// How the key is unlocked with a passphrase; null in a key file that has none.
        let kdf: Anything?
    }

    public static func status() throws -> Status {
        guard let stored = try Keychain.get(.encryptionKey), let key = try? JSONDecoder().decode(KeyFile.self, from: stored) else {
            return Status(present: false, fingerprint: nil, created: nil)
        }
        return Status(present: true, fingerprint: key.fingerprint, created: key.created, foreign: !Seal.holds(key: stored))
    }

    /// A file name for handing a key to the client and back, in a folder of its own that only
    /// the owner can enter and that is removed when `body` returns. The client wants a path to
    /// write the key to; it makes the file readable by the owner only. The folder is where
    /// other programs of the owner are kept out as well (`Paths.guarded`), as far as this
    /// build has such a place.
    private static func withScratchFile<T>(_ body: (URL) throws -> T) throws -> T {
        try Paths.createFolders()
        try FileManager.default.createDirectory(at: Paths.guarded, withIntermediateDirectories: true)
        let folder = Paths.guarded.appendingPathComponent("key-\(UUID().uuidString)")
        guard mkdir(folder.path, 0o700) == 0 else {
            throw Failure(description: "No folder for the new key in \(Paths.guarded.path): \(String(cString: strerror(errno))).")
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        return try body(folder.appendingPathComponent("key"))
    }

    /// Creates a key without a passphrase of its own; the Keychain protects it. Refuses when a
    /// key exists, unless `replacing`: earlier backups can then only be read with the old key's
    /// recovery copy. Errors never quote the client's output, which could hold key material.
    /// The client that makes the key knows it, so a release build takes only its own
    /// developer's client for this too.
    public static func create(client: URL, replacing: Bool = false) throws -> Status {
        guard try replacing || !status().present else { throw Failure(description: "There is an encryption key already.") }
        if let requirement = try Client.requirement(), !Signature.isSigned(client, as: requirement) {
            throw Failure(description: "\(client.path) is not signed the way this app's developer signs its client, so it made no key. Install the app again.")
        }
        try withScratchFile { file in
            let made = tool(client.path, ["key", "create", file.path, "--kdf", "none"], environment: Client.environment())
            guard made.status == 0, let key = try? Data(contentsOf: file) else {
                throw Failure(description: "The client could not create a key (exit status \(made.status)).")
            }
            try Keychain.set(.encryptionKey, key)
        }
        return try status()
    }

    /// Stores a key file, such as the recovery copy made on another Mac. A key file that is
    /// locked with a passphrase is refused: the client would ask for it at every backup, and a
    /// backup that runs by itself has nobody to ask.
    public static func importKey(_ data: Data) throws -> Status {
        // A typed-in paper key may still have its marker lines and the text around them.
        var data = data
        let text = String(decoding: data, as: UTF8.self)
        if let begin = text.range(of: "-----BEGIN PROXMOX BACKUP KEY-----"), let end = text.range(of: "-----END PROXMOX BACKUP KEY-----") {
            data = Data(text[begin.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        }
        guard let file = try? JSONDecoder().decode(KeyFile.self, from: data) else {
            throw Failure(description: "This is not an encryption key file.")
        }
        guard file.kdf == nil else {
            throw Failure(description: """
                This key file is locked with a passphrase, and a backup that runs by itself cannot ask for one. \
                Make a copy of the file, take the passphrase off the copy with \
                “proxmox-backup-client key change-passphrase <copy> --kdf none” and import the copy. \
                The Keychain protects the key from then on.
                """)
        }
        try Keychain.set(.encryptionKey, data)
        return try status()
    }

    /// Writes the recovery copy: the key file itself, readable by the owner only from the
    /// moment it exists. It is written under another name beside `url` and then moved there,
    /// which replaces an earlier file in one step.
    public static func export(to url: URL) throws {
        guard let key = try Keychain.get(.encryptionKey) else { throw Failure(description: "There is no encryption key yet.") }
        let scratch = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent)-\(UUID().uuidString)")
        do {
            let descriptor = open(scratch.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try file.write(contentsOf: key)
            try file.close()
            // Not replaceItemAt: that keeps metadata of the file it replaces, and so its permissions.
            guard rename(scratch.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            unlink(scratch.path)
            throw Failure(description: "The recovery file could not be written: \(error.localizedDescription)")
        }
    }

    /// The key as text to print and keep on paper, in the form `proxmox-backup-client key
    /// paperkey` prints it: the key file between two marker lines. Typed back into a file, with
    /// or without the markers' surroundings, it is the recovery copy. (The client's own command
    /// needs the `qrencode` program, so the text is made here.)
    public static func paperKey(subject: String) throws -> String {
        guard let key = try Keychain.get(.encryptionKey), let status = try? status() else {
            throw Failure(description: "There is no encryption key yet.")
        }
        return """
            Encryption key for the backups of \(subject)
            Fingerprint: \(status.fingerprint ?? "unknown")
            Created: \(status.created ?? "unknown")

            Keep this page somewhere safe. Whoever has it can read the backups; without it or the
            key file nobody can. To use it, type everything from BEGIN to END into a file and
            import that file in the app's settings.

            -----BEGIN PROXMOX BACKUP KEY-----
            \(String(decoding: key, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            -----END PROXMOX BACKUP KEY-----
            """
    }
}

/// The certificate a server presents, to show its fingerprint when the client would not take
/// it without one.
public enum ServerCertificate {
    public struct Info: Codable, Equatable {
        /// SHA-256 of the certificate, as the client and the PBS dashboard show it.
        public let fingerprint: String
        /// Whether the client accepts the certificate without being given its fingerprint.
        public let trusted: Bool
    }

    /// The roots the client trusts: the ones macOS ships as a file, the only ones `Client` lets
    /// the client's OpenSSL see. A root the owner added to the Keychain is not among them.
    public static let roots = "/etc/ssl/cert.pem"

    /// The certificates in a PEM file; none when it cannot be read.
    static func certificates(inPEMFile path: String) -> [SecCertificate] {
        guard let file = FileManager.default.contents(atPath: path) else { return [] }
        return String(decoding: file, as: UTF8.self).components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst().compactMap { block in
            guard let end = block.range(of: "-----END CERTIFICATE-----"),
                  let der = Data(base64Encoded: String(block[..<end.lowerBound]), options: .ignoreUnknownCharacters) else { return nil }
            return SecCertificateCreateWithData(nil, der as CFData)
        }
    }

    /// Whether the client will take the chain in `trust` as it is. It is judged the way the
    /// client's OpenSSL judges it: by the roots in the file alone, for the name the server was
    /// asked under, and without fetching a certificate the server did not send. macOS by
    /// itself also counts a root the owner added to the Keychain, which the client never sees;
    /// such a certificate has to be confirmed by its fingerprint. So has every certificate
    /// when the file cannot be read.
    static func accepted(_ trust: SecTrust, roots: String = ServerCertificate.roots) -> Bool {
        let anchors = certificates(inPEMFile: roots)
        guard !anchors.isEmpty,
              SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }

    private final class Probe: NSObject, URLSessionDelegate {
        var info: Info?
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if let trust = challenge.protectionSpace.serverTrust,
               let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first {
                let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
                info = Info(fingerprint: digest.hex(separator: ":"),
                            trusted: ServerCertificate.accepted(trust))
            }
            completionHandler(.cancelAuthenticationChallenge, nil)     // only looking, never sending anything
        }
    }

    /// Nil when the server cannot be reached.
    public static func fetch(host: String, port: Int) async -> Info? {
        guard let url = URL(string: "https://\(host.contains(":") ? "[\(host)]" : host):\(port)/") else { return nil }
        let probe = Probe()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: configuration, delegate: probe, delegateQueue: nil)
        _ = try? await session.data(from: url)
        session.invalidateAndCancel()
        return probe.info
    }
}

public enum FullDiskAccess {
    /// Whether this process may read everything in the home folder, which mounting an APFS
    /// snapshot also depends on. The permission databases are the usual thing to try: they
    /// can be opened with Full Disk Access only. The one of the whole Mac is on every Mac; the
    /// user's own is not there on newer versions of macOS (not on 27).
    public static var granted: Bool {
        let databases = ["/Library/Application Support/com.apple.TCC/TCC.db",
                         Paths.home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path]
        for database in databases {
            let file = open(database, O_RDONLY)
            if file >= 0 {
                close(file)
                return true
            }
        }
        return false
    }
}
