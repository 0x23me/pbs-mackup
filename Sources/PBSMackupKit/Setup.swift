import CryptoKit
import Foundation

/// The encryption key in the Keychain: creating, importing and the recovery copies. Only the
/// run tool calls these, because it owns the Keychain items.
public enum KeyStore {
    public struct Status: Codable, Equatable {
        public let present: Bool
        public let fingerprint: String?
        public let created: String?
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        public init(description: String) { self.description = description }
    }

    private struct KeyFile: Decodable {
        let data: String
        let fingerprint: String?
        let created: String?
    }

    public static func status() throws -> Status {
        guard let stored = try Keychain.get(.encryptionKey), let key = try? JSONDecoder().decode(KeyFile.self, from: stored) else {
            return Status(present: false, fingerprint: nil, created: nil)
        }
        return Status(present: true, fingerprint: key.fingerprint, created: key.created)
    }

    /// A private file for handing a key to the client and back, removed when `body` returns.
    private static func withScratchFile<T>(_ body: (URL) throws -> T) throws -> T {
        try Paths.createFolders()
        let file = Paths.cache.appendingPathComponent("key-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        return try body(file)
    }

    /// Creates a key without a passphrase of its own; the Keychain protects it. Refuses when a
    /// key exists, unless `replacing`: earlier backups can then only be read with the old key's
    /// recovery copy. Errors never quote the client's output, which could hold key material.
    public static func create(client: URL, replacing: Bool = false) throws -> Status {
        guard try replacing || !status().present else { throw Failure(description: "There is an encryption key already.") }
        try withScratchFile { file in
            let made = tool(client.path, ["key", "create", file.path, "--kdf", "none"])
            guard made.status == 0, let key = try? Data(contentsOf: file) else {
                throw Failure(description: "The client could not create a key (exit status \(made.status)).")
            }
            try Keychain.set(.encryptionKey, key)
        }
        return try status()
    }

    /// Stores a key file, such as the recovery copy made on another Mac.
    public static func importKey(_ data: Data) throws -> Status {
        // A typed-in paper key may still have its marker lines and the text around them.
        var data = data
        let text = String(decoding: data, as: UTF8.self)
        if let begin = text.range(of: "-----BEGIN PROXMOX BACKUP KEY-----"), let end = text.range(of: "-----END PROXMOX BACKUP KEY-----") {
            data = Data(text[begin.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        }
        guard (try? JSONDecoder().decode(KeyFile.self, from: data)) != nil else {
            throw Failure(description: "This is not an encryption key file.")
        }
        try Keychain.set(.encryptionKey, data)
        return try status()
    }

    /// Writes the recovery copy: the key file itself, readable by the owner only.
    public static func export(to url: URL) throws {
        guard let key = try Keychain.get(.encryptionKey) else { throw Failure(description: "There is no encryption key yet.") }
        try key.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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

/// The certificate a server presents, to show its fingerprint when it is not publicly trusted.
public enum ServerCertificate {
    public struct Info: Codable, Equatable {
        /// SHA-256 of the certificate, as the client and the PBS dashboard show it.
        public let fingerprint: String
        public let trusted: Bool
    }

    private final class Probe: NSObject, URLSessionDelegate {
        var info: Info?
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if let trust = challenge.protectionSpace.serverTrust,
               let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first {
                let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
                info = Info(fingerprint: digest.map { String(format: "%02x", $0) }.joined(separator: ":"),
                            trusted: SecTrustEvaluateWithError(trust, nil))
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
                         FileManager.default.homeDirectoryForCurrentUser
                             .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path]
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
