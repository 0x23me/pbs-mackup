import CryptoKit
import Foundation

/// What the app and the run tool last stored themselves: the configuration, and the encryption
/// key. Any program of the user can rewrite config.json, and can delete a Keychain item and put
/// one of its own in its place. The seal is kept where macOS lets only this developer's
/// programs write (`Paths.seal`), so a run can tell a configuration or a key that came from
/// somewhere else and refuses to use it.
public struct Seal: Codable, Equatable {
    /// SHA-256 of the configuration, see `digest(of:)`.
    var config: String?
    /// SHA-256 of the encryption key as it is in the Keychain.
    var key: String?

    public static let configChanged = "The settings were changed outside the app, so nothing is backed up or read until you have "
        + "looked at them: open Settings and click Done. (After editing config.json by hand: pbs-mackup-run seal.)"
    public static let keyChanged = "The encryption key in the Keychain is not the one this app put there, so it is not used. "
        + "Import the recovery copy of your key in Settings."

    public static func load() -> Seal {
        guard let data = try? Data(contentsOf: Paths.seal), let seal = try? JSONDecoder().decode(Seal.self, from: data) else {
            return Seal()
        }
        return seal
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: Paths.seal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Paths.seal, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.seal.path)
    }

    /// The digest of what a configuration says, not of how its file is written: the same
    /// settings give the same digest whatever the order of the keys and the spacing.
    static func digest(of config: Config) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: (try? encoder.encode(config)) ?? Data()).hex()
    }

    /// Notes `config` as the configuration to go by.
    public static func set(config: Config) throws {
        var seal = load()
        seal.config = digest(of: config)
        try seal.save()
    }

    /// Notes `key` as the encryption key to go by.
    public static func set(key: Data) throws {
        var seal = load()
        seal.key = SHA256.hash(data: key).hex()
        try seal.save()
    }

    // Nothing notes a configuration or a key just because it is there and the seal has none:
    // whoever can remove the seal, or gets in before there is one, would have theirs taken
    // over. Without a seal the owner says which ones count: Done in the settings window or
    // `pbs-mackup-run seal` for the configuration, importing the recovery copy for the key.

    public static func holds(_ config: Config) -> Bool { load().config == digest(of: config) }

    public static func holds(key: Data) -> Bool { load().key == SHA256.hash(data: key).hex() }
}
