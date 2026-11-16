import AppKit
import CoreServices

/// The owner's "Open at Login" list, read and added to with Apple Events to System Events.
/// macOS asks the owner once before a program may send them; the app asks (`permission(ask:
/// true)`), and the grant covers the run tool, which macOS counts as the app's. A run only ever
/// checks without asking, so it never shows a prompt.
public enum LoginItems {
    public enum Permission: Equatable {
        case granted
        /// The owner hasn't been asked yet.
        case notAsked
        /// The owner said no, or turned it off in System Settings.
        case denied
        case unknown(OSStatus)
    }

    static let systemEvents = "com.apple.systemevents"
    private static let loginItem: DescType = 0x6C6F_6769     // 'logi'
    private static let name: DescType = 0x706E_616D          // 'pnam'
    private static let path: DescType = 0x7070_7468          // 'ppth'
    private static let properties: DescType = 0x7041_4C4C    // 'pALL'

    /// Whether this program may send Apple Events to System Events. With `ask` the owner is
    /// asked when they haven't been yet; it waits for their answer.
    public static func permission(ask: Bool) -> Permission {
        guard launchSystemEvents() else { return .unknown(OSStatus(procNotFound)) }
        let target = NSAppleEventDescriptor(bundleIdentifier: systemEvents)
        guard let address = target.aeDesc else { return .unknown(OSStatus(errAEEventFailed)) }
        switch AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, ask) {
        case noErr: return .granted
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        case OSStatus(errAEEventNotPermitted): return .denied
        case let status: return .unknown(status)
        }
    }

    /// Why login items can't be read, in words for the manifest and the Settings window; nil
    /// when they can.
    public static func reason(_ permission: Permission) -> String? {
        switch permission {
        case .granted: return nil
        case .notAsked: return "PBS Mackup hasn't been allowed to read login items. Allow it in Settings, under Record login items."
        case .denied: return "PBS Mackup isn't allowed to control System Events. Turn it on in System Settings > Privacy & Security > Automation."
        case .unknown(let status): return "System Events didn't answer (error \(status))."
        }
    }

    /// The "Open at Login" list, without asking for permission. Throws with the reason when it
    /// can't be read, or when System Events takes longer than `timeout` seconds.
    public static func read(timeout: TimeInterval = 5) throws -> [LoginItem] {
        if let reason = reason(permission(ask: false)) { throw Failure(description: reason) }
        let every = specifier(want: loginItem, form: OSType(formAbsolutePosition),
                              key: NSAppleEventDescriptor(descriptorType: typeAbsoluteOrdinal, bytes: [kAEAll], length: 4)!,
                              from: .null())
        let event = self.event(AEEventID(kAEGetData))
        event.setParam(specifier(want: OSType(cProperty), form: OSType(formPropertyID),
                                 key: NSAppleEventDescriptor(typeCode: properties), from: every), forKeyword: keyDirectObject)
        return parse(try send(event, timeout: timeout))
    }

    /// Adds the app at `url` to the "Open at Login" list.
    public static func add(_ url: URL, timeout: TimeInterval = 5) throws {
        if let reason = reason(permission(ask: false)) { throw Failure(description: reason) }
        let event = self.event(AEEventID(kAECreateElement))
        event.setParam(NSAppleEventDescriptor(typeCode: loginItem), forKeyword: AEKeyword(keyAEObjectClass))
        let values = NSAppleEventDescriptor.record()
        values.setDescriptor(NSAppleEventDescriptor(string: url.path), forKeyword: path)
        event.setParam(values, forKeyword: AEKeyword(keyAEPropData))
        _ = try send(event, timeout: timeout)
    }

    /// What can be done with a recorded login item on this Mac.
    public enum Restorable: Equatable {
        /// It is in the "Open at Login" list already.
        case done
        /// Its app is installed here, at this place.
        case add(URL)
        case installFirst
    }

    public static func restorable(_ item: LoginItem, current: [LoginItem], installed: URL?) -> Restorable {
        if contains(current, item) { return .done }
        return installed.map(Restorable.add) ?? .installFirst
    }

    /// Where the app of a recorded login item is on this Mac: found by its bundle identifier,
    /// wherever it lives now, or else at the recorded path.
    public static func installed(_ item: LoginItem) -> URL? {
        if let id = item.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        return FileManager.default.fileExists(atPath: item.path) ? URL(fileURLWithPath: item.path) : nil
    }

    /// Whether `item` is in `list`: the same app by bundle identifier where both know it, by
    /// path otherwise.
    public static func contains(_ list: [LoginItem], _ item: LoginItem) -> Bool {
        list.contains { present in
            if let wanted = item.bundleID, let found = present.bundleID { return wanted == found }
            return present.path == item.path
        }
    }

    /// The items in System Events' answer to `get properties of every login item`: a list of
    /// records. The bundle identifier comes from the app at each path, through `bundleID`.
    static func parse(_ reply: NSAppleEventDescriptor,
                      bundleID: (String) -> String? = { Bundle(path: $0)?.bundleIdentifier }) -> [LoginItem] {
        guard reply.numberOfItems > 0 else { return [] }
        return (1...reply.numberOfItems).compactMap { index in
            guard let record = reply.atIndex(index),
                  let path = record.forKeyword(path)?.stringValue, !path.isEmpty else { return nil }
            let name = record.forKeyword(name)?.stringValue ?? (path as NSString).lastPathComponent
            return LoginItem(name: name, bundleID: bundleID(path), path: path)
        }
    }

    // MARK: - Apple Events

    private static func event(_ id: AEEventID) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(eventClass: AEEventClass(kAECoreSuite), eventID: id,
                               targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: systemEvents),
                               returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    }

    private static func specifier(want: DescType, form: OSType, key: NSAppleEventDescriptor,
                                  from container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(key, forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        return record.coerce(toDescriptorType: DescType(typeObjectSpecifier)) ?? record
    }

    /// Sends `event` and returns the direct result, or throws with System Events' error.
    private static func send(_ event: NSAppleEventDescriptor, timeout: TimeInterval) throws -> NSAppleEventDescriptor {
        let reply: NSAppleEventDescriptor
        do { reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: timeout) } catch {
            throw Failure(description: "System Events didn't answer: \(error.localizedDescription)")
        }
        if let number = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value, number != noErr {
            let text = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue
            throw Failure(description: "System Events refused: \(text ?? "error \(number)")")
        }
        return reply.paramDescriptor(forKeyword: keyDirectObject) ?? .list()
    }

    /// System Events has to run to answer, and isn't started by an event sent to it.
    private static func launchSystemEvents() -> Bool {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: systemEvents).isEmpty { return true }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: systemEvents) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        let done = DispatchSemaphore(value: 0)
        var launched = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, _ in
            launched = app != nil
            done.signal()
        }
        return done.wait(timeout: .now() + 5) == .success && launched
    }
}
