// restore-check: seeds a home folder with the Mac metadata a restore has to bring back, records
// what is in a folder (a manifest), and compares two manifests.
//
//   restore-check seed <home>                      test files in <home>/RestoreTest, a keychain item
//   restore-check manifest <folder> <out.tsv> [--no-content]
//   restore-check compare <before.tsv> <after.tsv> [--details <file>] [--ignore <prefix>]...
//
// Build: swiftc -O restore-check.swift -o restore-check
// A manifest of a whole home folder is taken as root from a terminal that has Full Disk Access.

import CryptoKit
import Darwin
import Foundation

let args = CommandLine.arguments
func die(_ message: String) -> Never { FileHandle.standardError.write((message + "\n").data(using: .utf8)!); exit(1) }

/// Flags macOS sets by itself; a restored file is stored uncompressed.
let systemFlags = UInt32(UF_COMPRESSED) | UInt32(UF_TRACKED)
let datalessFlag: UInt32 = 0x4000_0000
/// Attributes macOS manages and does not let anyone set.
let unsettableAttributes: Set<String> = ["com.apple.macl", "com.apple.provenance"]

func escape(_ s: String) -> String {
    s.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "\t", with: "%09").replacingOccurrences(of: "\n", with: "%0A")
}

func hex(_ digest: some Sequence<UInt8>, _ count: Int = 16) -> String {
    digest.prefix(count).map { String(format: "%02x", $0) }.joined()
}

// MARK: manifest

func aclText(_ path: String) -> String {
    guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return "" }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    var length = 0
    guard let text = acl_to_text(acl, &length) else { return "?" }
    defer { acl_free(text) }
    return String(cString: text).split(separator: "\n").filter { !$0.hasPrefix("!#acl") }.joined(separator: ";")
}

func xattrList(_ path: String) -> [String] {
    let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
    guard size > 0 else { return [] }
    var names = [CChar](repeating: 0, count: size)
    guard listxattr(path, &names, size, XATTR_NOFOLLOW) == size else { return ["?"] }
    return names.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }.sorted()
}

func xattrs(_ path: String) -> String {
    xattrList(path).map { name -> String in
        let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return "\(name)=?" }
        var value = [UInt8](repeating: 0, count: size)
        if size > 0, getxattr(path, name, &value, size, 0, XATTR_NOFOLLOW) != size { return "\(name)=?" }
        return "\(name)=\(size):\(hex(SHA256.hash(data: value), 6))"
    }.joined(separator: "|")
}

func contentHash(_ path: String) -> String {
    let fd = open(path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { return "E\(errno)" }
    defer { close(fd) }
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 1 << 20)
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n < 0 { return "E\(errno)" }
        if n == 0 { break }
        hasher.update(data: buffer[0..<n])
    }
    return hex(hasher.finalize())
}

func manifest(root: String, out: String, content: Bool) {
    let root = (root as NSString).standardizingPath
    guard FileManager.default.createFile(atPath: out, contents: nil), let file = FileHandle(forWritingAtPath: out) else { die("cannot write \(out)") }
    var lines: [String] = ["#\troot=\(root)\tcontent=\(content)"]
    var count = 0
    func flush() { file.write((lines.joined(separator: "\n") + "\n").data(using: .utf8)!); lines.removeAll(keepingCapacity: true) }

    var paths: [UnsafeMutablePointer<CChar>?] = [strdup(root), nil]
    defer { free(paths[0]) }
    guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { die("cannot open \(root)") }
    defer { fts_close(fts) }
    while let entry = fts_read(fts) {
        let info = Int32(entry.pointee.fts_info)
        if info == FTS_DP { continue }
        let path = String(cString: entry.pointee.fts_path)
        let relative = path == root ? "." : String(path.dropFirst(root.count + 1))
        if info == FTS_DNR || info == FTS_ERR || info == FTS_NS {
            lines.append([escape(relative), "E", String(cString: strerror(entry.pointee.fts_errno))].joined(separator: "\t"))
            continue
        }
        var st = stat()
        guard lstat(path, &st) == 0 else { lines.append("\(escape(relative))\tE\t\(String(cString: strerror(errno)))"); continue }
        let kind: String
        switch st.st_mode & S_IFMT {
        case S_IFREG: kind = "f"
        case S_IFDIR: kind = "d"
        case S_IFLNK: kind = "l"
        default: kind = "o"
        }
        let flags = st.st_flags & ~systemFlags
        var link = "", sha = ""
        if kind == "l" {
            var target = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let n = readlink(path, &target, target.count - 1)
            link = n >= 0 ? String(cString: target) : "?"
        } else if kind == "f" && content {
            sha = flags & datalessFlag != 0 ? "dataless" : contentHash(path)
        }
        let size = kind == "d" ? "-" : String(st.st_size)
        let mtime = kind == "l" ? "-" : "\(st.st_mtimespec.tv_sec).\(String(format: "%09ld", st.st_mtimespec.tv_nsec))"
        let birth = "\(st.st_birthtimespec.tv_sec).\(String(format: "%09ld", st.st_birthtimespec.tv_nsec))"
        let hardlink = kind == "f" && st.st_nlink > 1 ? "\(st.st_ino)" : "-"
        lines.append([escape(relative), kind, "\(st.st_uid):\(st.st_gid)", String(st.st_mode & 0o7777, radix: 8),
                      String(flags, radix: 16), size, mtime, birth, hardlink, escape(link), escape(aclText(path)),
                      escape(xattrs(path)), sha].joined(separator: "\t"))
        count += 1
        if lines.count >= 2000 { flush() }
    }
    flush()
    try? file.close()
    print("\(count) items in \(root) -> \(out)")
}

// MARK: compare

struct Item {
    var fields: [String]
    var kind: String { fields[1] }
    subscript(_ i: Int) -> String { i < fields.count ? fields[i] : "" }
}

func load(_ path: String) -> [String: Item] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { die("cannot read \(path)") }
    var items: [String: Item] = [:]
    for line in text.split(separator: "\n") where !line.hasPrefix("#") {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        items[fields[0]] = Item(fields: fields)
    }
    return items
}

/// What every backup leaves out, so missing after a restore is expected.
let leftOut = ["Library/Caches", ".Trash"]
let leftOutNames: Set<String> = [".DS_Store", ".TemporaryItems", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".Trashes"]

func isLeftOut(_ path: String) -> Bool {
    if leftOut.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
    return path.split(separator: "/").contains { leftOutNames.contains(String($0)) }
}

func compare(before beforePath: String, after afterPath: String, details: String?, ignore: [String]) {
    let before = load(beforePath), after = load(afterPath)
    let ignored = { (p: String) in ignore.contains { p == $0 || p.hasPrefix($0 + "/") } }
    var findings: [String: [(String, String)]] = [:]
    func note(_ category: String, _ path: String, _ what: String = "") { findings[category, default: []].append((path, what)) }

    for (path, b) in before where !ignored(path) {
        guard let a = after[path] else { note(isLeftOut(path) ? "missing (left out by design)" : "missing", path); continue }
        if b.kind == "E" || a.kind == "E" { if b.kind != a.kind { note("unreadable", path, "\(b[2]) -> \(a[2])") }; continue }
        if b.kind != a.kind { note("type", path, "\(b.kind) -> \(a.kind)"); continue }
        if b[2] != a[2] { note("owner", path, "\(b[2]) -> \(a[2])") }
        if b[3] != a[3] { note("mode", path, "\(b[3]) -> \(a[3])") }
        if b[4] != a[4] { note("flags", path, "\(b[4]) -> \(a[4])") }
        if b.kind == "f" && b[5] != a[5] { note("size", path, "\(b[5]) -> \(a[5])") }
        if b.kind == "f" && !b[12].isEmpty && !a[12].isEmpty && b[12] != "dataless" && b[12] != a[12] { note("content", path) }
        if b[6] != a[6] { note(b.kind == "d" ? "modified date (folder)" : "modified date", path, "\(b[6]) -> \(a[6])") }
        if b[7] != a[7] { note("creation date", path, "\(b[7]) -> \(a[7])") }
        if b[9] != a[9] { note("symlink target", path, "\(b[9]) -> \(a[9])") }
        if b[10] != a[10] { note("acl", path, "\(b[10]) -> \(a[10])") }
        if b[11] != a[11] {
            let parse = { (s: String) -> [String: String] in
                Dictionary(s.split(separator: "|").map { kv -> (String, String) in
                    let parts = kv.split(separator: "=", maxSplits: 1); return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
                }, uniquingKeysWith: { x, _ in x })
            }
            let bx = parse(b[11]), ax = parse(a[11])
            for (name, value) in bx {
                let category = unsettableAttributes.contains(name) ? "xattr (macOS-managed)" : "xattr"
                if ax[name] == nil { note(category, path, "lost \(name)") } else if ax[name] != value { note(category, path, "changed \(name)") }
            }
            for name in ax.keys where bx[name] == nil {
                note(unsettableAttributes.contains(name) || name == "com.apple.quarantine" ? "xattr (macOS-managed)" : "xattr", path, "new \(name)")
            }
        }
    }
    for path in after.keys where before[path] == nil && !ignored(path) { note("new", path) }

    // Hard links: paths that shared an inode before must share one after.
    var groups: [String: [String]] = [:]
    for (path, b) in before where b[8] != "-" && !ignored(path) { groups[b[8], default: []].append(path) }
    for paths in groups.values where paths.count > 1 {
        let inodes = Set(paths.compactMap { after[$0]?[8] })
        if inodes.count != 1 || inodes.first == "-" { note("hard link", paths.sorted().joined(separator: " + "), "no longer one file") }
    }

    print("before: \(before.count) items   after: \(after.count) items\n")
    if findings.isEmpty { print("No differences."); return }
    let order = ["missing", "type", "content", "size", "owner", "mode", "flags", "acl", "xattr", "creation date", "modified date",
                 "symlink target", "hard link", "unreadable", "modified date (folder)", "xattr (macOS-managed)", "new", "missing (left out by design)"]
    var report = ""
    for category in order + findings.keys.filter({ !order.contains($0) }).sorted() {
        guard let list = findings[category] else { continue }
        print("\(category): \(list.count)")
        // Where they are: grouped by the first three folders.
        var byPlace: [String: Int] = [:]
        for (path, _) in list { byPlace[path.split(separator: "/").prefix(3).joined(separator: "/"), default: 0] += 1 }
        for (place, n) in byPlace.sorted(by: { $0.value > $1.value }).prefix(8) { print("    \(String(n).padding(toLength: 7, withPad: " ", startingAt: 0)) \(place)") }
        if byPlace.count > 8 { print("    ... \(byPlace.count - 8) more places") }
        for (path, what) in list.sorted(by: { $0.0 < $1.0 }) { report += "\(category)\t\(path)\t\(what)\n" }
    }
    if let details { try? report.write(toFile: details, atomically: true, encoding: .utf8); print("\nevery difference: \(details)") }
}

// MARK: seed

func seed(home: String) {
    let root = home + "/RestoreTest"
    let fm = FileManager.default
    if fm.fileExists(atPath: root) { die("\(root) exists already") }
    func path(_ name: String) -> String { root + "/" + name }
    func write(_ name: String, _ data: [UInt8], mode: mode_t = 0o644) {
        let fd = open(path(name), O_WRONLY | O_CREAT | O_EXCL, mode)
        guard fd >= 0 else { die("cannot create \(name): \(String(cString: strerror(errno)))") }
        if !data.isEmpty { _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) } }
        close(fd)
    }
    func text(_ name: String, _ s: String, mode: mode_t = 0o644) { write(name, Array(s.utf8), mode: mode) }
    func random(_ n: Int) -> [UInt8] { (0..<n).map { _ in UInt8.random(in: 0...255) } }
    func dir(_ name: String, mode: mode_t = 0o755) { if mkdir(path(name), mode) != 0 { die("mkdir \(name)") } ; chmod(path(name), mode) }
    func run(_ tool: String, _ arguments: [String]) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = arguments
        do { try p.run(); p.waitUntilExit() } catch { die("\(tool): \(error)") }
        if p.terminationStatus != 0 { print("  ! \(tool) \(arguments.joined(separator: " ")) failed") }
    }
    func setx(_ name: String, _ attribute: String, _ value: [UInt8]) {
        if setxattr(path(name), attribute, value, value.count, 0, XATTR_NOFOLLOW) != 0 { print("  ! \(attribute) on \(name): \(String(cString: strerror(errno)))") }
    }

    if mkdir(root, 0o755) != 0 { die("cannot create \(root)") }
    text("plain.txt", "plain\n")
    text("empty.txt", "")
    text("Cafe\u{301}-decomposed.txt", "NFD name\n")
    text("Caf\u{e9}-composed.txt", "NFC name\n")
    text(String(repeating: "x", count: 251) + ".txt", "255-byte name\n")
    text("private.txt", "mode 600\n", mode: 0o600)
    text("script.sh", "#!/bin/sh\necho restored\n", mode: 0o755)
    dir("private-folder", mode: 0o700)
    text("private-folder/inside.txt", "in a 700 folder\n")
    dir("empty-folder")
    var deep = "deep"
    dir(deep)
    for i in 1...30 { deep += "/\(i)"; dir(deep) }
    text(deep + "/bottom.txt", "30 folders down\n")
    write("random-32MiB.bin", random(32 << 20))

    // Sparse: 256 MiB with one byte at the end.
    let fd = open(path("sparse.bin"), O_WRONLY | O_CREAT | O_EXCL, 0o644)
    ftruncate(fd, 256 << 20 - 1); lseek(fd, 0, SEEK_END); _ = Darwin.write(fd, "!", 1); close(fd)

    // Links.
    symlink("plain.txt", path("link-relative"))
    symlink("/etc/hosts", path("link-absolute"))
    symlink("does-not-exist", path("link-dangling"))
    symlink("deep", path("link-to-folder"))
    text("hardlink-a.txt", "one file, two names\n")
    link(path("hardlink-a.txt"), path("hardlink-b.txt"))

    // Dates: created 2000, modified 2010.
    text("old-dates.txt", "created 2000-01-01, modified 2010-01-01\n")
    try? fm.setAttributes([.creationDate: Date(timeIntervalSince1970: 946_684_800),
                           .modificationDate: Date(timeIntervalSince1970: 1_262_304_000)], ofItemAtPath: path("old-dates.txt"))

    // Finder: tags, colour label, type and creator, resource fork, hidden, locked.
    text("tagged.txt", "tags Red and Projekt\n")
    try? (URL(fileURLWithPath: path("tagged.txt")) as NSURL).setResourceValue(["Red", "Projekt"], forKey: .tagNamesKey)
    text("typed.txt", "type TEXT, creator ttxt\n")
    setx("typed.txt", "com.apple.FinderInfo", Array("TEXTttxt".utf8) + [UInt8](repeating: 0, count: 24))
    text("resource-fork.txt", "3 MiB resource fork\n")
    setx("resource-fork.txt", "com.apple.ResourceFork", random(3 << 20))
    text("binary-xattr.txt", "a binary attribute with zero bytes\n")
    setx("binary-xattr.txt", "me.0x23.restore-test", [0, 1, 2, 0, 255, 0])
    text("quarantined.txt", "downloaded, says the quarantine attribute\n")
    setx("quarantined.txt", "com.apple.quarantine", Array("0083;6560a1b2;Safari;".utf8))
    text("hidden.txt", "hidden from Finder\n")
    chflags(path("hidden.txt"), UInt32(UF_HIDDEN))
    text("locked.txt", "Finder's Locked\n")
    dir("locked-folder")
    text("locked-folder/inside.txt", "in a locked folder\n")
    chflags(path("locked-folder/inside.txt"), UInt32(UF_IMMUTABLE))

    // ACLs, as Desktop and Documents have them, and an inherited one.
    text("acl-deny-delete.txt", "everyone deny delete\n")
    run("/bin/chmod", ["+a", "everyone deny delete", path("acl-deny-delete.txt")])
    dir("acl-inherit")
    run("/bin/chmod", ["+a", "staff allow list,add_file,search,delete_child,file_inherit,directory_inherit", path("acl-inherit")])
    text("acl-inherit/child.txt", "inherits from its folder\n")
    chflags(path("locked.txt"), UInt32(UF_IMMUTABLE))
    chflags(path("locked-folder"), UInt32(UF_IMMUTABLE))

    // A keychain item in the login keychain, only when seeding one's own home folder.
    guard (home as NSString).standardizingPath == NSHomeDirectory() else { print("seeded \(root) (no keychain item: not your home folder)"); return }
    run("/usr/bin/security", ["add-generic-password", "-U", "-a", NSUserName(), "-s", "pbs-mackup-restore-test", "-w", "restore-me"])
    print("seeded \(root), and the keychain item pbs-mackup-restore-test")
    print("after the restore: security find-generic-password -s pbs-mackup-restore-test -w   (says restore-me)")
}

// MARK: main

switch args.count > 1 ? args[1] : "" {
case "seed" where args.count == 3:
    seed(home: args[2])
case "manifest" where args.count >= 4:
    manifest(root: args[2], out: args[3], content: !args.contains("--no-content"))
case "compare" where args.count >= 4:
    var details: String?, ignore: [String] = [], i = 4
    while i < args.count {
        if args[i] == "--details", i + 1 < args.count { details = args[i + 1]; i += 2 }
        else if args[i] == "--ignore", i + 1 < args.count { ignore.append(args[i + 1]); i += 2 }
        else { die("unknown option \(args[i])") }
    }
    compare(before: args[2], after: args[3], details: details, ignore: ignore)
default:
    die("""
    restore-check seed <home>
    restore-check manifest <folder> <out.tsv> [--no-content]
    restore-check compare <before.tsv> <after.tsv> [--details <file>] [--ignore <prefix>]...
    """)
}
