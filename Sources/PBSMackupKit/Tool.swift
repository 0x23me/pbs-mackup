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
///
/// Nothing below `folder` is reached by a path, see `Tree`: a link in it is removed and never
/// followed, whoever puts one there meanwhile, and `folder` itself is only removed, not
/// followed, when it is a link. Still, root uses this only where nobody else can put anything
/// (`HomeRestore.Places.staging`): a lock comes off whatever lies in the folder, and that can
/// be a second name of a file that is someone else's. Returns what could not be removed.
@discardableResult
func removeRestored(_ folder: URL) -> Leftovers {
    var left = Leftovers()
    guard exists(folder) else { return left }
    guard let (parent, name) = Tree.parent(of: folder) else {
        left.add(folder.path)
        return left
    }
    defer { close(parent) }
    Tree.remove(name, in: parent, at: folder.path, left: &left)
    return left
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
