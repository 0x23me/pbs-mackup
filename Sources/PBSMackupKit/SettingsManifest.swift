import Foundation

/// The settings of this Mac that live outside the backed-up folders, as a run records them
/// with every backup (`settings.json`, uploaded as `settings.conf`). Each kind of setting is a
/// section of its own. A reader ignores sections it does not know, so a manifest from a newer
/// version opens in an older app; `format` changes only when a section changes incompatibly.
public struct SettingsManifest: Codable, Equatable {
    public static let currentFormat = 1

    public var format: Int
    public var taken: Date
    public var macOS: String
    public var loginItems: Section<LoginItem>

    public init(format: Int = SettingsManifest.currentFormat, taken: Date = Date(),
                macOS: String = SettingsManifest.systemVersion, loginItems: Section<LoginItem>) {
        self.format = format
        self.taken = taken
        self.macOS = macOS
        self.loginItems = loginItems
    }

    /// The version of macOS this runs on, as `27.2` or `27.2.1`.
    public static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder.iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> SettingsManifest {
        try JSONDecoder.iso8601.decode(SettingsManifest.self, from: data)
    }
}

/// One kind of setting: what was found, or why it could not be read.
public struct Section<Item: Codable & Equatable>: Codable, Equatable {
    public enum Status: String, Codable { case ok, unavailable }

    public var status: Status
    public var reason: String?
    public var items: [Item]

    public static func ok(_ items: [Item]) -> Section { Section(status: .ok, reason: nil, items: items) }
    public static func unavailable(_ reason: String) -> Section { Section(status: .unavailable, reason: reason, items: []) }
}

/// An app in the owner's "Open at Login" list. Whether it opens hidden isn't recorded: macOS
/// has ignored that flag since 13, and System Events reports it as false whatever was set.
public struct LoginItem: Codable, Equatable, Hashable {
    public var name: String
    /// From the app at `path` when it was recorded; nil where that had none.
    public var bundleID: String?
    public var path: String

    public init(name: String, bundleID: String?, path: String) {
        self.name = name
        self.bundleID = bundleID
        self.path = path
    }
}

extension SettingsManifest {
    /// What a run records. A section that can't be read within `timeout` seconds, or fails, is
    /// unavailable with the reason; capturing never fails and never asks for a permission.
    public static func capture(timeout: TimeInterval = 5,
                               loginItems read: @escaping () throws -> [LoginItem] = { try LoginItems.read() }) -> SettingsManifest {
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: Section<LoginItem> = .unavailable("System Events didn't answer within \(Int(timeout)) seconds.")
        // On a thread of its own, so that a System Events that hangs holds up the backup by no more than `timeout`.
        Thread.detachNewThread {
            let section: Section<LoginItem>
            do { section = .ok(try read()) } catch { section = .unavailable("\(error)") }
            lock.lock(); defer { lock.unlock() }
            result = section
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
        lock.lock(); defer { lock.unlock() }
        return SettingsManifest(loginItems: result)
    }
}
