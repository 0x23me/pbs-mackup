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
