import Darwin
import Foundation

/// Something that went wrong, as a sentence for the owner. `Client.Failure` and
/// `KeyStore.Failure` are this.
public struct Failure: Error, CustomStringConvertible, LocalizedError {
    public let description: String
    public init(description: String) { self.description = description }
    public var errorDescription: String? { description }
}

/// Runs a system tool to completion and returns its exit status and combined output. Its
/// standard input is empty. Without an `environment` it gets this program's.
@discardableResult
public func tool(_ path: String, _ arguments: [String], environment: [String: String]? = nil) -> (status: Int32, output: String) {
    do {
        let result = try Child(URL(fileURLWithPath: path), arguments, environment: environment, mergingErrors: true).finish()
        return (result.status, String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    } catch { return (-1, "\(error.localizedDescription)") }
}

/// `path` with every link in it followed; nil when there is no such item. Not
/// `resolvingSymlinksInPath`: that one drops /private from /private/var, and inside a snapshot
/// there is no /var link.
func realPath(_ path: String) -> String? {
    guard let pointer = realpath(path, nil) else { return nil }
    defer { free(pointer) }
    return String(cString: pointer)
}

/// Whether there is an item at `url`. A link counts by itself, also when it leads nowhere.
func exists(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0
}

/// Removes a folder that holds items restored from a backup. The client gives a restored item
/// the metadata it had, and that can keep it from being deleted: a lock (Finder's Locked), an
/// ACL that forbids it (as on ~/Downloads), or a folder its owner may not write to. All three
/// are taken off first, by this program itself and not by `chflags` and `chmod`: such a folder
/// can lie where macOS lets other programs in only after asking (`Paths.guarded`).
func removeRestored(_ folder: URL) {
    func unlock(_ item: URL) {
        var info = stat()
        guard lstat(item.path, &info) == 0 else { return }
        // The lock first: a locked item does not let go of its ACL either.
        let locks = UInt32(UF_IMMUTABLE | UF_APPEND)
        if info.st_flags & locks != 0 { lchflags(item.path, info.st_flags & ~locks) }
        if let none = acl_init(0) {
            acl_set_link_np(item.path, ACL_TYPE_EXTENDED, none)
            acl_free(UnsafeMutableRawPointer(none))
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { return }
        chmod(item.path, (info.st_mode & 0o7777) | 0o700)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: item.path)) ?? [] {
            unlock(item.appendingPathComponent(name))
        }
    }
    guard exists(folder) else { return }
    unlock(folder)
    try? FileManager.default.removeItem(at: folder)
}

extension Sequence where Element == UInt8 {
    /// Two hexadecimal digits per byte, with `separator` between the bytes.
    func hex(separator: String = "") -> String {
        map { String(format: "%02x", $0) }.joined(separator: separator)
    }
}

extension JSONEncoder {
    /// Writes dates as the state file has them, ISO 8601 in UTC.
    public static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    public static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
