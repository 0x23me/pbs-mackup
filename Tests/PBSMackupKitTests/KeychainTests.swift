import Foundation
import Security
import Testing
@testable import PBSMackupKit

// How a secret gets into the Keychain, which keychain that is and how the items of an earlier
// version get there, with a stand-in for the Keychain itself: the tests keep their secrets in
// files and never touch a Keychain. Where the app is, seen from the run tool. And which log
// the menu opens.

/// One Keychain item: what lies there, whose it is, and what was asked of the Keychain.
private final class Slot {
    var value: Data?
    /// Another program made the item and lets nobody else remove it.
    var foreign = false
    /// What the next calls to add answer, before they go back to storing.
    var refusals: [OSStatus] = []
    /// The Keychain would ask the owner before it hands the item over, and may not ask.
    var unreadable = false
    var calls: [String] = []

    init(_ value: String? = nil, foreign: Bool = false) {
        self.value = value.map { Data($0.utf8) }
        self.foreign = foreign
    }

    var store: Keychain.Store {
        Keychain.Store(
            delete: {
                self.calls.append("delete")
                guard self.value != nil else { return errSecItemNotFound }
                guard !self.foreign else { return errSecInvalidOwnerEdit }
                self.value = nil
                return errSecSuccess
            },
            add: { value in
                self.calls.append("add")
                if !self.refusals.isEmpty { return self.refusals.removeFirst() }
                guard self.value == nil else { return errSecDuplicateItem }
                self.value = value
                return errSecSuccess
            },
            read: {
                self.calls.append("read")
                if self.unreadable { throw Keychain.Failure(status: errSecAuthFailed) }
                return self.value
            })
    }

    var text: String? { value.map { String(decoding: $0, as: UTF8.self) } }
}

private func failure(_ work: () throws -> Void) -> String? {
    do { try work(); return nil } catch { return "\(error)" }
}

@Test func aSecretGoesIntoAKeychainItemThatIsMadeAnew() throws {
    // Nothing there yet.
    var slot = Slot()
    try Keychain.replace(.token, with: Data("new".utf8), in: slot.store)
    #expect(slot.text == "new")
    // An item that is there, this tool's or one another program left open to all: removed
    // and made anew, never changed where it lies.
    slot = Slot("old")
    try Keychain.replace(.token, with: Data("new".utf8), in: slot.store)
    #expect(slot.text == "new")
    #expect(slot.calls == ["delete", "add"])
}

@Test func aKeychainItemOfAnotherProgramTakesNoSecret() {
    // Another program made an item under the name first and waits for the secret.
    let slot = Slot("planted", foreign: true)
    let said = failure { try Keychain.replace(.encryptionKey, with: Data("the key".utf8), in: slot.store) }
    #expect(said?.hasPrefix("Another program holds a Keychain item named \(Keychain.service) (account encryption-key)") == true, "\(said ?? "")")
    #expect(said?.hasSuffix("Delete that item in Keychain Access, then try again.") == true)
    #expect(slot.text == "planted")
    #expect(slot.calls == ["delete"])

    // It puts the item there between the removal and the new one: the same is said.
    let raced = Slot("old")
    raced.refusals = [errSecDuplicateItem]
    let again = failure { try Keychain.replace(.token, with: Data("new".utf8), in: raced.store) }
    #expect(again?.hasPrefix("Another program holds a Keychain item named \(Keychain.service) (account token)") == true, "\(again ?? "")")

    // Any other failure is said as the Keychain says it.
    let broken = Slot()
    broken.refusals = [errSecIO]
    let plain = failure { try Keychain.replace(.token, with: Data("new".utf8), in: broken.store) }
    #expect(plain == Keychain.Failure(status: errSecIO).description && plain?.contains("Another program") == false)
}

@Test func theKeychainIsChosenByWhatMacOSSaysTheProgramMayUse() {
    let group = "33C888LZ98.me.0x23.pbs-mackup"
    // The run tool of a build with a provisioning profile: macOS names the access group.
    #expect(Keychain.place(groups: [group], team: "33C888LZ98", bundleID: "me.0x23.pbs-mackup") == .guarded(group: group))
    // No profile, so no group: an ad-hoc build, a build by someone else, the app, the tests.
    #expect(Keychain.place(groups: nil, team: "33C888LZ98", bundleID: "me.0x23.pbs-mackup") == .login)
    #expect(Keychain.place(groups: [], team: "33C888LZ98", bundleID: "me.0x23.pbs-mackup") == .login)
    #expect(Keychain.place(groups: nil, team: nil, bundleID: "me.0x23.pbs-mackup") == .login)
    // A group of another app or another developer is not the one the items are in.
    #expect(Keychain.place(groups: ["33C888LZ98.com.example.other"], team: "33C888LZ98", bundleID: "me.0x23.pbs-mackup") == .login)
    #expect(Keychain.place(groups: [group], team: "ABCDE12345", bundleID: "me.0x23.pbs-mackup") == .login)
    #expect(Keychain.place(groups: [group], team: nil, bundleID: "me.0x23.pbs-mackup") == .login)
    // The tests themselves have no group.
    #expect(Keychain.place == .login)
}

@Test func theItemsOfAnEarlierVersionAreTakenOutOfTheLoginKeychain() throws {
    // The token: taken over and removed where it was, so that an earlier run tool finds nothing.
    var new = Slot(), old = Slot("the token")
    #expect(try Keychain.get(.token, in: new.store, before: old.store, holds: { _ in false }) == Data("the token".utf8))
    #expect(new.text == "the token" && old.value == nil)
    #expect(old.calls == ["read", "delete"])
    // From then on what is in the login keychain is never read, only removed: what a program
    // puts there, and what an earlier run could not remove.
    old = Slot("planted")
    #expect(try Keychain.get(.token, in: new.store, before: old.store, holds: { _ in false }) == Data("the token".utf8))
    #expect(old.calls == ["delete"] && old.value == nil)

    // The key the seal holds: the same.
    new = Slot(); old = Slot("the key")
    #expect(try Keychain.get(.encryptionKey, in: new.store, before: old.store, holds: { $0 == Data("the key".utf8) }) == Data("the key".utf8))
    #expect(new.text == "the key" && old.value == nil)

    // Nothing in either place.
    new = Slot(); old = Slot()
    #expect(try Keychain.get(.encryptionKey, in: new.store, before: old.store, holds: { _ in true }) == nil)
    #expect(new.value == nil)
}

@Test func aKeyInTheLoginKeychainThatTheSealDoesNotHoldIsNotTakenOver() throws {
    // Another program put a key there, or exchanged the one that was there. It is handed on,
    // so that the owner is told it is not theirs, and it becomes nobody's key: it stays
    // where it is and the new place stays empty.
    let new = Slot(), old = Slot("planted")
    #expect(try Keychain.get(.encryptionKey, in: new.store, before: old.store, holds: { _ in false }) == Data("planted".utf8))
    #expect(new.value == nil && new.calls == ["read"])
    #expect(old.text == "planted" && old.calls == ["read"])

    // An item there that macOS would ask the owner about is another program's: not there.
    let asked = Slot("planted")
    asked.unreadable = true
    #expect(try Keychain.get(.token, in: new.store, before: asked.store, holds: { _ in true }) == nil)
    #expect(new.value == nil && asked.text == "planted" && asked.calls == ["read"])

    // The new place takes nothing: the item still serves, and stays for the next time.
    let full = Slot(), kept = Slot("the token")
    full.refusals = [errSecIO]
    #expect(try Keychain.get(.token, in: full.store, before: kept.store, holds: { _ in false }) == Data("the token".utf8))
    #expect(full.value == nil && kept.text == "the token")
    #expect(try Keychain.get(.token, in: full.store, before: kept.store, holds: { _ in false }) == Data("the token".utf8))
    #expect(full.text == "the token" && kept.value == nil)
}

@Test func theAppIsFoundFromWhereverTheRunToolLiesInIt() {
    func app(_ path: String) -> String? { Identity.app(of: URL(fileURLWithPath: path))?.path }
    func client(_ path: String) -> String { Client.bundled(for: URL(fileURLWithPath: path)).path }
    // The app itself, and the run tool next to it.
    #expect(app("/Applications/PBSMackup.app/Contents/MacOS/PBSMackup") == "/Applications/PBSMackup.app")
    #expect(app("/Applications/PBSMackup.app/Contents/MacOS/pbs-mackup-run") == "/Applications/PBSMackup.app")
    #expect(client("/Applications/PBSMackup.app/Contents/MacOS/pbs-mackup-run") == "/Applications/PBSMackup.app/Contents/Helpers/proxmox-backup-client")
    // The run tool in a bundle of its own inside the app: still the app, not that bundle.
    let nested = "/Applications/PBSMackup.app/Contents/Helpers/PBSMackupRun.app/Contents/MacOS/pbs-mackup-run"
    #expect(app(nested) == "/Applications/PBSMackup.app")
    #expect(client(nested) == "/Applications/PBSMackup.app/Contents/Helpers/proxmox-backup-client")
    // Wherever the app lies, also in a folder that is named like an app.
    #expect(app("/Users/me/Old.app/PBSMackup.app/Contents/Helpers/PBSMackupRun.app/Contents/MacOS/pbs-mackup-run") == "/Users/me/Old.app/PBSMackup.app")
    #expect(app("/Users/me/pbs-mackup/.build/PBSMackup.app/Contents/Helpers/PBSMackupRun.app/Contents/MacOS/pbs-mackup-run")
        == "/Users/me/pbs-mackup/.build/PBSMackup.app")
    // No bundle: a development build, and the program that runs the tests, which is inside Xcode.
    #expect(app("/Users/me/pbs-mackup/.build/debug/pbs-mackup-run") == nil)
    #expect(app("/Applications/Xcode.app/Contents/Developer/usr/bin/xctest") == nil)
    #expect(app("/Applications/PBSMackup.app/Contents/Helpers/proxmox-backup-client") == nil)
    #expect(client("/Users/me/pbs-mackup/.build/debug/pbs-mackup-run") == "/Users/me/pbs-mackup/.build/Helpers/proxmox-backup-client")
    #expect(Identity.app == nil && Identity.bundleID == "me.0x23.pbs-mackup")
}

extension PrivateHomeTests {
@Test func onlyALogInTheLogsFolderIsOpened() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("pbs-mackup-logs-\(UUID().uuidString)")
    setenv("PBS_MACKUP_HOME", home.path, 1)
    defer { unsetenv("PBS_MACKUP_HOME"); try? FileManager.default.removeItem(at: home) }
    try Paths.createFolders()
    let folder = Paths.logs
    func opened(_ named: String?) -> String { Paths.logToOpen(named).path }
    func resolved(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

    // The log a run names in its record.
    let log = folder.appendingPathComponent("2026-11-12T140005.log")
    try Data("run success\n".utf8).write(to: log)
    #expect(opened(log.path) == resolved(log))
    // No record, or a log that is gone after its 30 days: the folder.
    #expect(opened(nil) == folder.path)
    #expect(opened(folder.appendingPathComponent("2026-10-01T080000.log").path) == folder.path)

    // What another program wrote into the state file is not opened, wherever it lies:
    let script = home.appendingPathComponent("elsewhere/run-me.command")
    try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: script)
    #expect(opened(script.path) == folder.path)
    #expect(opened("/System/Applications/Calculator.app") == folder.path)
    #expect(opened(folder.path + "/../../elsewhere/run-me.command") == folder.path)
    // not in the logs folder under another name, nor as a link from there, nor further down,
    try FileManager.default.copyItem(at: script, to: folder.appendingPathComponent("run-me.command"))
    #expect(opened(folder.appendingPathComponent("run-me.command").path) == folder.path)
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("linked.log"), withDestinationURL: script)
    #expect(opened(folder.appendingPathComponent("linked.log").path) == folder.path)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("deeper"), withIntermediateDirectories: true)
    try Data().write(to: folder.appendingPathComponent("deeper/a.log"))
    #expect(opened(folder.appendingPathComponent("deeper/a.log").path) == folder.path)
    // and no folder that is named like a log.
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("folder.log"), withIntermediateDirectories: true)
    #expect(opened(folder.appendingPathComponent("folder.log").path) == folder.path)
}
}
