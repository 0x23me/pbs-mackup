import Foundation
import Testing
@testable import PBSMackupKit

// The settings manifest a run records with every backup: what a newer version adds is ignored,
// and a section that could not be read keeps its reason.

@Test func aManifestFromANewerVersionOpensWithTheSectionsThisOneKnows() throws {
    let newer = #"""
        {
          "format": 1,
          "taken": "2026-11-16T09:00:00Z",
          "macOS": "27.2",
          "dock": { "status": "ok", "items": [ { "tile": "Safari" } ] },
          "loginItems": { "status": "ok", "items": [
            { "name": "Raycast", "bundleID": "com.raycast.macos", "path": "/Applications/Raycast.app", "since": 3 }
          ] }
        }
        """#
    let manifest = try SettingsManifest.decode(Data(newer.utf8))
    #expect(manifest.taken == Date(timeIntervalSince1970: 1_794_819_600))
    #expect(manifest.macOS == "27.2")
    #expect(manifest.loginItems == .ok([LoginItem(name: "Raycast", bundleID: "com.raycast.macos", path: "/Applications/Raycast.app")]))
}

@Test func anUnavailableSectionKeepsItsReason() throws {
    let manifest = SettingsManifest(taken: Date(timeIntervalSince1970: 1_794_819_600), macOS: "27.2",
                                    loginItems: .unavailable("Automation for System Events is not allowed."))
    let decoded = try SettingsManifest.decode(manifest.encoded())
    #expect(decoded == manifest)
    #expect(decoded.loginItems.status == .unavailable)
    #expect(decoded.loginItems.reason == "Automation for System Events is not allowed.")
    #expect(decoded.loginItems.items.isEmpty)
}

@Test func aLoginItemWithoutBundleIdentifierRoundTrips() throws {
    let item = LoginItem(name: "script", bundleID: nil, path: "/Users/me/bin/script.app")
    let manifest = SettingsManifest(taken: Date(timeIntervalSince1970: 1_794_819_600), loginItems: .ok([item]))
    #expect(try SettingsManifest.decode(manifest.encoded()).loginItems.items == [item])
}

extension PrivateHomeTests {
    /// A snapshot with a settings manifest: its archives stay the folders alone, and the manifest
    /// is fetched by itself with `restore <snapshot> settings.conf -`.
    @Test func theManifestIsFetchedAloneAndIsNoArchive() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pbs-mackup-manifest-\(UUID().uuidString)")
        setenv("PBS_MACKUP_HOME", home.path, 1)
        defer { unsetenv("PBS_MACKUP_HOME"); try? FileManager.default.removeItem(at: home) }
        try Keychain.set(.token, Data("token".utf8))
        try Keychain.set(.encryptionKey, Data("key".utf8))
        let standIn = home.appendingPathComponent("client")
        try Data(#"""
            #!/bin/sh
            cat > /dev/null
            case "$1" in
                snapshot) echo '[{"backup-type":"host","backup-id":"test-mac","backup-time":1,"files":[{"filename":"Downloads.pxar.didx"},{"filename":"settings.conf.blob"},{"filename":"index.json.blob"}]},
                                 {"backup-type":"host","backup-id":"test-mac","backup-time":0,"files":[{"filename":"Downloads.pxar.didx"}]}]' ;;
                restore) printf '%s\n' "$@" > "$PBS_MACKUP_HOME/arguments"
                         echo '{"format":1,"taken":"2026-11-16T09:00:00Z","macOS":"27.2","loginItems":{"status":"ok","items":[{"name":"Raycast","path":"/Applications/Raycast.app"}]}}' ;;
            esac
            """#.utf8).write(to: standIn)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: standIn.path)
        let config = Config(repository: "test@pbs!mac@127.0.0.1:0:store", namespace: "test", backupID: "test-mac",
                            sources: [], clientPath: standIn.path)
        let client = try Client(config: config)

        let snapshots = try client.snapshots()
        #expect(snapshots.map(\.archives) == [["Downloads.pxar"], ["Downloads.pxar"]])
        #expect(snapshots.map(\.hasSettings) == [true, false])

        let manifest = try client.settings(snapshot: snapshots[0].name)
        #expect(manifest.loginItems.items == [LoginItem(name: "Raycast", bundleID: nil, path: "/Applications/Raycast.app")])
        let arguments = try String(contentsOf: home.appendingPathComponent("arguments"), encoding: .utf8).split(separator: "\n")
        #expect(arguments.prefix(4) == ["restore", "host/test-mac/1970-01-01T00:00:01Z", "settings.conf", "-"])
        // Nothing else passes for a name; the manifest isn't one of the folders.
        #expect(throws: Client.Failure.self) { try client.settings(snapshot: "host/test-mac/now") }
        #expect(throws: Client.Failure.self) { try Client.check(archives: ["settings.json"]) }
    }
}

@Test func macSettingsIsOffInAConfigurationFromBeforeItAndKeepsItsSeal() throws {
    let before = #"{"repository":"u@pbs!t@host:store","namespace":"mac","backupID":"my-mac","sources":["/Users/me"],"excludes":[],"frozenSnapshot":"whenPermitted"}"#
    var config = try JSONDecoder().decode(Config.self, from: Data(before.utf8))
    #expect(!config.macSettingsOn)
    // Off is not written, so the digest the seal holds for such a configuration stays the same.
    let digest = Seal.digest(of: config)
    config.macSettings = nil
    #expect(Seal.digest(of: config) == digest)
    config.macSettings = true
    #expect(config.macSettingsOn)
    #expect(Seal.digest(of: config) != digest)
}
