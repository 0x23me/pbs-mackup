import Foundation
import Testing
@testable import PBSMackupKit

// Reading System Events' answer about login items, and telling whether a recorded one is
// already in the list. Nothing here sends an Apple Event.

private func code(_ text: String) -> DescType { text.utf8.reduce(0) { $0 << 8 | DescType($1) } }

/// A record as System Events answers `get properties of every login item`, recorded on macOS 27.2.
private func record(_ name: String, _ path: String) -> NSAppleEventDescriptor {
    let record = NSAppleEventDescriptor.record()
    record.setDescriptor(NSAppleEventDescriptor(typeCode: code("logi")), forKeyword: code("pcls"))
    record.setDescriptor(NSAppleEventDescriptor(string: name), forKeyword: code("pnam"))
    record.setDescriptor(NSAppleEventDescriptor(string: path), forKeyword: code("ppth"))
    record.setDescriptor(NSAppleEventDescriptor(boolean: false), forKeyword: code("hidn"))
    record.setDescriptor(NSAppleEventDescriptor(string: "Application"), forKeyword: code("kind"))
    return record
}

@Test func theAnswerOfSystemEventsBecomesLoginItemsWithTheirBundleIdentifiers() {
    let reply = NSAppleEventDescriptor.list()
    reply.insert(record("Raycast", "/Applications/Raycast.app"), at: 1)
    reply.insert(record("Lasso", "/Applications/Lasso.app"), at: 2)
    reply.insert(record("script", "/Users/me/bin/script"), at: 3)
    let identifiers = ["/Applications/Raycast.app": "com.raycast.macos", "/Applications/Lasso.app": "com.heavylightapps.lasso"]
    #expect(LoginItems.parse(reply, bundleID: { identifiers[$0] }) == [
        LoginItem(name: "Raycast", bundleID: "com.raycast.macos", path: "/Applications/Raycast.app"),
        LoginItem(name: "Lasso", bundleID: "com.heavylightapps.lasso", path: "/Applications/Lasso.app"),
        LoginItem(name: "script", bundleID: nil, path: "/Users/me/bin/script"),
    ])
    #expect(LoginItems.parse(.list(), bundleID: { _ in nil }).isEmpty)
}

@Test func anItemWithoutPathIsLeftOutAndOneWithoutNameIsNamedAfterItsPath() {
    let reply = NSAppleEventDescriptor.list()
    reply.insert(record("gone", ""), at: 1)
    let nameless = NSAppleEventDescriptor.record()
    nameless.setDescriptor(NSAppleEventDescriptor(string: "/Applications/Flux.app"), forKeyword: code("ppth"))
    reply.insert(nameless, at: 2)
    #expect(LoginItems.parse(reply, bundleID: { _ in nil }) == [LoginItem(name: "Flux.app", bundleID: nil, path: "/Applications/Flux.app")])
}

@Test func aRecordedItemIsPresentByBundleIdentifierAndOtherwiseByPath() {
    let list = [LoginItem(name: "Raycast", bundleID: "com.raycast.macos", path: "/Applications/Utilities/Raycast.app"),
                LoginItem(name: "script", bundleID: nil, path: "/Users/me/bin/script")]
    // Moved to another folder: the same app.
    #expect(LoginItems.contains(list, LoginItem(name: "Raycast", bundleID: "com.raycast.macos", path: "/Applications/Raycast.app")))
    // Another app at the path a recorded one had: not the same.
    #expect(!LoginItems.contains(list, LoginItem(name: "Other", bundleID: "com.other", path: "/Applications/Utilities/Raycast.app")))
    // Without a bundle identifier on either side, the path decides.
    #expect(LoginItems.contains(list, LoginItem(name: "script", bundleID: nil, path: "/Users/me/bin/script")))
    #expect(LoginItems.contains(list, LoginItem(name: "Raycast", bundleID: nil, path: "/Applications/Utilities/Raycast.app")))
    #expect(!LoginItems.contains(list, LoginItem(name: "Flux", bundleID: "org.herf.Flux", path: "/Applications/Flux.app")))
}

@Test func aRecordedItemIsDoneAddableOrToBeInstalledFirst() {
    let raycast = LoginItem(name: "Raycast", bundleID: "com.raycast.macos", path: "/Applications/Raycast.app")
    let moved = URL(fileURLWithPath: "/Applications/Utilities/Raycast.app")
    #expect(LoginItems.restorable(raycast, current: [raycast], installed: moved) == .done)
    // Found by bundle identifier at its new place, that is the one added.
    #expect(LoginItems.restorable(raycast, current: [], installed: moved) == .add(moved))
    #expect(LoginItems.restorable(raycast, current: [], installed: nil) == .installFirst)
}
