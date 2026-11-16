import CryptoKit
import Darwin
import Foundation

/// After a backup, a few files are restored from the new snapshot and compared with what was
/// backed up: the proof, on every run, that what the client wrote can be read back.
public enum SampleCheck {
    /// Attributes macOS manages itself and does not let a restore set.
    static let unrestorableAttributes: Set<String> = ["com.apple.macl", "com.apple.provenance"]
    /// Flags the system sets on its own: compressed (a restored file is stored uncompressed) and tracked.
    static let systemFlags: UInt32 = UInt32(UF_COMPRESSED) | UInt32(UF_TRACKED)
    static let timeMachineExclusion = "com.apple.metadata:com_apple_backup_excludeItem"

    /// Picks up to `count` regular files below `root`, at most `maxBytes` together, by walking
    /// down random folders, and prefers the most recently modified of what it found. Skips what
    /// the backup leaves out: the default exclusions and the owner's own (`excludes`),
    /// placeholders, anything excluded from Time Machine, other volumes mounted in the folder,
    /// and files that cannot be opened.
    public static func pick(in root: URL, count: Int, maxBytes: Int64, excludes: [String] = []) -> [String] {
        let rules = Config.defaultExcludes + excludes
        var top = stat()
        guard stat(root.path, &top) == 0 else { return [] }
        var found: [String: (size: Int64, modified: timespec)] = [:]
        for _ in 0..<(count * 6) {
            var relative: [String] = []
            for _ in 0..<64 {
                let folder = relative.reduce(root) { $0.appendingPathComponent($1) }
                guard let name = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.randomElement() else { break }
                relative.append(name)
                // Judged at every step down, so a rule for a folder also covers what is in it.
                let below = relative.joined(separator: "/")
                if rules.contains(where: { LeaveOut.matches($0, relative: below) }) { break }
                // At the top the client keeps the rules it was given under this name and never
                // reads a file called so.
                if below == ".pxarexclude-cli" { break }
                let path = folder.appendingPathComponent(name).path
                var info = stat()
                guard lstat(path, &info) == 0, info.st_dev == top.st_dev, info.st_flags & UInt32(SF_DATALESS) == 0,
                      getxattr(path, timeMachineExclusion, nil, 0, 0, XATTR_NOFOLLOW) < 0 else { break }
                if info.st_mode & S_IFMT == S_IFDIR { continue }
                if info.st_mode & S_IFMT == S_IFREG, info.st_size <= maxBytes {
                    let file = open(path, O_RDONLY)
                    guard file >= 0 else { break }      // the backup left it out with a warning
                    close(file)
                    found[relative.joined(separator: "/")] = (info.st_size, info.st_mtimespec)
                }
                break
            }
        }
        var picked: [String] = []
        var bytes: Int64 = 0
        for (path, file) in found.sorted(by: { ($0.value.modified.tv_sec, $0.key) > ($1.value.modified.tv_sec, $1.key) })
        where picked.count < count && bytes + file.size <= maxBytes {
            picked.append(path)
            bytes += file.size
        }
        return picked
    }

    /// Whether the picker can go by `rule`: whether `LeaveOut.matches` leaves out at least what
    /// the client leaves out for it. Not so for `**`, which it judges loosely; for `[…]`, which
    /// the client reads its own way; and for a rule the client tidies up before it uses it
    /// (`./name`, `a//b`, `..`). A rule that starts with `!` only ever keeps more in the
    /// backup, which does the picker no harm.
    static func canJudge(_ rule: String) -> Bool {
        if rule.hasPrefix("!") { return true }
        // A character after a backslash stands for itself, whatever it is.
        var plain = "", escaped = false
        for character in rule {
            if escaped { plain.append("x"); escaped = false }
            else if character == "\\" { escaped = true }
            else { plain.append(character) }
        }
        let parts = plain.split(separator: "/", omittingEmptySubsequences: false)
        return !plain.contains("**") && !plain.contains("[")
            && !parts.contains(".") && !parts.contains("..") && !parts.dropFirst().dropLast().contains("")
    }

    /// Whether the snapshot may rightly lack a picked file although no rule the picker knows
    /// leaves it out. That is so below a folder with rules of its own (a `.pxarexclude` file,
    /// which the client obeys), and, when the live folders were read (`liveSince` is when the
    /// run began), for a file that came since or lies in a folder that did: the client may have
    /// been there before it.
    static func mayBeAbsent(_ relative: String, in root: URL, liveSince start: Date?) -> Bool {
        func isSince(_ time: timespec) -> Bool {
            start.map { Double(time.tv_sec) + Double(time.tv_nsec) / 1e9 >= $0.timeIntervalSince1970 } ?? false
        }
        var item = root, info = stat()
        // Whether something came into the folder at hand, or left it.
        var folderChanged = lstat(root.path, &info) == 0 && isSince(info.st_mtimespec)
        for name in relative.split(separator: "/") {
            if FileManager.default.fileExists(atPath: item.appendingPathComponent(".pxarexclude").path) { return true }
            item.appendPathComponent(String(name))
            guard lstat(item.path, &info) == 0 else { return start != nil }     // and gone again
            // Made, moved here or renamed: that sets the change time of the item, also when
            // it keeps an old modification date, and the modification date of its folder.
            if folderChanged && isSince(info.st_ctimespec) { return true }
            folderChanged = isSince(info.st_mtimespec)
        }
        return false
    }

    /// Restores a picked file into `target`, where it appears under its own name. `extract`
    /// restores one path of the archive into a folder, as `catalog extract` does.
    ///
    /// A file with more than one name is stored once, under the name the backup came to first;
    /// each later name is stored as a link to that path, which the client can only make once
    /// that name is restored into the same folder as well. So when such a file cannot be
    /// restored on its own, its other names in the folder the link points into are restored
    /// first, each where it lies in the archive, and then the file once more. What is compared
    /// afterwards is the content stored under the first name, which is this file's content too.
    static func restore(_ relative: String, in folder: URL, into target: URL,
                        extract: (_ path: String, _ into: URL) throws -> Void) throws {
        do {
            try extract(relative, target)
        } catch let failure {
            var file = stat()
            guard !Client.isMissingPath(failure), lstat(folder.appendingPathComponent(relative).path, &file) == 0,
                  file.st_mode & S_IFMT == S_IFREG, file.st_nlink > 1 else { throw failure }
            // The client names the folder of the first name when it cannot open it; a first name
            // at the top of the archive has no folder to name.
            let linked = hardLinkFolder(in: "\(failure)") ?? ""
            let place = linked.isEmpty ? folder : folder.appendingPathComponent(linked)
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: place.path)) ?? [])
                .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            for name in names {
                let path = linked.isEmpty ? name : linked + "/" + name
                var info = stat()
                guard path != relative, lstat(place.appendingPathComponent(name).path, &info) == 0,
                      info.st_dev == file.st_dev, info.st_ino == file.st_ino else { continue }
                do {
                    let into = linked.isEmpty ? target : target.appendingPathComponent(linked)
                    try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
                    try extract(path, into)
                    try extract(relative, target)
                    return
                } catch {
                    continue        // not the name the link points to, or not restorable either
                }
            }
            throw failure
        }
    }

    /// The folder a hard link points into, from the client's words when it cannot open it:
    /// `failed to open hardlink target directory "<folder>"`, the folder written as Rust writes
    /// a path, with `\"`, `\\`, `\'`, `\n`, `\u{308}`, `\xff` and the like. Nil when the words
    /// are not there.
    static func hardLinkFolder(in message: String) -> String? {
        guard let start = message.range(of: "failed to open hardlink target directory \"") else { return nil }
        var scalars = message[start.upperBound...].unicodeScalars.makeIterator()
        var bytes: [UInt8] = []
        func hex(until end: Unicode.Scalar?, count: Int?) -> UInt32? {
            var digits = ""
            while count.map({ digits.count < $0 }) ?? true, let scalar = scalars.next(), scalar != end { digits.unicodeScalars.append(scalar) }
            return UInt32(digits, radix: 16)
        }
        while let scalar = scalars.next() {
            switch scalar {
            case "\"":
                return String(decoding: bytes, as: UTF8.self)
            case "\\":
                switch scalars.next() {
                case "t": bytes.append(9)
                case "n": bytes.append(10)
                case "r": bytes.append(13)
                case "0": bytes.append(0)
                case "x":
                    guard let byte = hex(until: nil, count: 2), byte <= 0xFF else { return nil }
                    bytes.append(UInt8(byte))
                case "u":
                    guard scalars.next() == "{", let value = hex(until: "}", count: nil),
                          let decoded = Unicode.Scalar(value) else { return nil }
                    bytes += Array(String(decoded).utf8)
                case let other?:
                    bytes += Array(String(other).utf8)
                case nil:
                    return nil
                }
            default:
                bytes += Array(String(scalar).utf8)
            }
        }
        return nil
    }

    /// What differs between a file and its restored copy, in words; empty when nothing does.
    public static func differences(original: URL, restored: URL) -> [String] {
        guard let a = Fingerprint(original), let b = Fingerprint(restored) else { return ["cannot be read"] }
        var differences: [String] = []
        if a.size != b.size || a.contents != b.contents { differences.append("contents") }
        if a.modified != b.modified { differences.append("modification date") }
        if a.created != b.created { differences.append("creation date") }
        if a.mode != b.mode { differences.append("permissions") }
        if a.flags != b.flags { differences.append("flags") }
        if a.acl != b.acl { differences.append("access control list") }
        for name in Set(a.attributes.keys).union(b.attributes.keys).sorted() where a.attributes[name] != b.attributes[name] {
            differences.append("attribute \(name)")
        }
        return differences
    }

    struct Fingerprint {
        let size: Int64, mode: mode_t, flags: UInt32
        let modified: [Int], created: [Int]
        let contents: Data
        let attributes: [String: Data]
        let acl: String

        init?(_ url: URL) {
            var info = stat()
            guard lstat(url.path, &info) == 0, let file = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? file.close() }
            size = Int64(info.st_size)
            mode = info.st_mode
            flags = info.st_flags & ~SampleCheck.systemFlags
            modified = [info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec]
            created = [info.st_birthtimespec.tv_sec, info.st_birthtimespec.tv_nsec]
            var hash = SHA256()
            while let block = try? file.read(upToCount: 1 << 20), !block.isEmpty { hash.update(data: block) }
            contents = Data(hash.finalize())

            var found: [String: Data] = [:]
            let length = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
            if length > 0 {
                var names = [CChar](repeating: 0, count: length)
                let used = listxattr(url.path, &names, length, XATTR_NOFOLLOW)
                for name in names.prefix(max(used, 0)).split(separator: 0).map({ String(cString: Array($0) + [0]) })
                where !SampleCheck.unrestorableAttributes.contains(name) {
                    // Hashed in pieces: a resource fork can be large and is read by position.
                    var hash = SHA256(), offset = 0
                    var piece = [UInt8](repeating: 0, count: 1 << 20)
                    let total = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
                    while offset < total {
                        let position = name == XATTR_RESOURCEFORK_NAME ? UInt32(offset) : 0
                        let got = getxattr(url.path, name, &piece, piece.count, position, XATTR_NOFOLLOW)
                        guard got > 0 else { break }
                        hash.update(data: piece.prefix(got))
                        offset += got
                        if name != XATTR_RESOURCEFORK_NAME { break }
                    }
                    found[name] = Data(hash.finalize()) + withUnsafeBytes(of: total) { Data($0) }
                }
            }
            attributes = found

            if let list = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) {
                let text = acl_to_text(list, nil)
                acl = text.map { String(cString: $0) } ?? ""
                acl_free(UnsafeMutableRawPointer(text))
                acl_free(UnsafeMutableRawPointer(list))
            } else {
                acl = ""
            }
        }
    }
}
