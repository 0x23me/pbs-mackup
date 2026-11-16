import Darwin
import Foundation

/// File work below a folder, done so that nobody who can change the folder meanwhile can send
/// it elsewhere. A path is looked up anew at every call, and whoever owns a folder on the way
/// can put a link there between two of them; for root that is a way to anyone's files. So no
/// path is used below the folder the caller names: every folder is opened from the one above
/// it, never through a link, and an item is reached by its name in an open folder or, better,
/// by a descriptor of its own, which stays the item it was checked to be.
enum Tree {
    /// Finder's Locked and its kin: what keeps an item from being changed or deleted, also by root.
    static let locks = UInt32(UF_IMMUTABLE | UF_APPEND)

    private static let folderFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    /// The folder at `path`, opened; nil when the last name is a link or no folder. The names
    /// before it are followed as in any path: where a tree lies is for the caller to vouch for.
    static func open(_ path: String) -> Int32? {
        let fd = Darwin.open(path, folderFlags)
        return fd >= 0 ? fd : nil
    }

    /// The folder reached from the open folder `root` by `names`, one after the other and none
    /// of them a link; nil when one is a link, no folder or not there. `root` itself for no names.
    static func open(_ names: [String], below root: Int32) -> Int32? {
        var current = fcntl(root, F_DUPFD_CLOEXEC, 0)
        for name in names where current >= 0 {
            let next = openat(current, name, folderFlags)
            close(current)
            current = next
        }
        return current >= 0 ? current : nil
    }

    /// The folder `url` lies in, opened, and the name `url` has there.
    static func parent(of url: URL) -> (folder: Int32, name: String)? {
        let name = url.lastPathComponent
        guard !name.isEmpty, name != "/", name != ".", name != ".." else { return nil }
        let fd = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        return fd >= 0 ? (fd, name) : nil
    }

    /// A descriptor of the item `name` in the open folder `parent`, which `info` describes: of
    /// a link itself, never of what it points to. Nil for what has none, a socket, a pipe or a
    /// device (opening those does things), and when what is there by now is another item than
    /// `info` describes. `forcing` is for an item about to be deleted: where it keeps its owner
    /// out, it is made to let them in.
    static func descriptor(of name: String, in parent: Int32, matching info: stat, forcing: Bool = false) -> Int32? {
        let kind = info.st_mode & S_IFMT
        let flags: Int32
        switch kind {
        case S_IFDIR: flags = folderFlags
        // O_SYMLINK opens a link itself and everything else as it is.
        case S_IFREG, S_IFLNK: flags = O_RDONLY | O_SYMLINK | O_NONBLOCK | O_NOCTTY | O_CLOEXEC
        default: return nil
        }
        var fd = openat(parent, name, flags)
        if fd < 0, errno == EACCES, forcing, geteuid() != 0 {
            // Root is let in everywhere, so this is the owner: of an item whose mode or ACL
            // keeps even them from reading it. Both are changed by name, as there is no
            // descriptor yet; a user can do that only to what is theirs anyway. Root never
            // does: a mode set by name lands on whatever has that name by then.
            if info.st_flags & locks != 0 { setFlags(info.st_flags & ~locks, of: name, in: parent) }
            removeACL(of: name, in: parent)
            fchmodat(parent, name, (info.st_mode & 0o7777) | (kind == S_IFDIR ? 0o700 : 0o400), AT_SYMLINK_NOFOLLOW)
            fd = openat(parent, name, flags)
        }
        guard fd >= 0 else { return nil }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino,
              opened.st_mode & S_IFMT == kind else {
            close(fd)
            return nil
        }
        return fd
    }

    /// The names in an open folder.
    static func names(in folder: Int32) -> [String] {
        // A descriptor of its own for the listing, which closes it.
        let copy = fcntl(folder, F_DUPFD_CLOEXEC, 0)
        guard copy >= 0 else { return [] }
        guard let listing = fdopendir(copy) else { close(copy); return [] }
        defer { closedir(listing) }
        rewinddir(listing)
        var names: [String] = []
        while let entry = readdir(listing) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }

    /// Sets the flags of an item by its name in an open folder, for one that cannot be opened;
    /// a link's own.
    @discardableResult
    static func setFlags(_ flags: UInt32, of name: String, in parent: Int32) -> Bool {
        var list = attrlist(bitmapcount: UInt16(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: attrgroup_t(ATTR_CMN_FLAGS),
                            volattr: 0, dirattr: 0, fileattr: 0, forkattr: 0)
        var flags = flags
        return setattrlistat(parent, name, &list, &flags, MemoryLayout<UInt32>.size, UInt32(FSOPT_NOFOLLOW)) == 0
    }

    /// Takes the ACL off an item that cannot be opened. There is no call that does it by a
    /// name in an open folder, so this one goes by the path the folder has now, and is only
    /// for a user at what is theirs: root is not held by an ACL and never needs it.
    private static func removeACL(of name: String, in parent: Int32) {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard geteuid() != 0, fcntl(parent, F_GETPATH, &buffer) == 0, let none = acl_init(0) else { return }
        acl_set_link_np(String(cString: buffer) + "/" + name, ACL_TYPE_EXTENDED, none)
        acl_free(UnsafeMutableRawPointer(none))
    }

    // MARK: - Walking

    /// An item a walk came to.
    struct Item {
        /// The open folder it lies in, and its name there.
        let parent: Int32
        let name: String
        /// Where it lies below the folder the walk began at, which is ".".
        let path: String
        let info: stat
        /// A folder the walk goes into is open already.
        fileprivate let opened: Int32?

        /// Whether it is a socket, a pipe or a device, which has no descriptor to work on.
        var isSpecial: Bool {
            let kind = info.st_mode & S_IFMT
            return kind != S_IFDIR && kind != S_IFREG && kind != S_IFLNK
        }

        /// Runs `body` with a descriptor of the item, see `descriptor`; nil without running it
        /// when there is none to be had.
        @discardableResult
        func withDescriptor<T>(_ body: (Int32) -> T) -> T? {
            if let opened { return body(opened) }
            guard let fd = Tree.descriptor(of: name, in: parent, matching: info) else { return nil }
            defer { close(fd) }
            return body(fd)
        }
    }

    /// Calls `body` for `root` and every item below it, a folder before what is in it, without
    /// following links or leaving the volume.
    static func walk(_ root: URL, _ body: (Item) -> Void) {
        guard let (parent, name) = parent(of: root) else { return }
        defer { close(parent) }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return }
        visit(name, in: parent, at: ".", volume: info.st_dev, body)
    }

    private static func visit(_ name: String, in parent: Int32, at path: String, volume: dev_t, _ body: (Item) -> Void) {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return }
        // A folder of another volume is named and not gone into.
        let enter = info.st_mode & S_IFMT == S_IFDIR && info.st_dev == volume
        let fd = enter ? descriptor(of: name, in: parent, matching: info) : nil
        defer { if let fd { close(fd) } }
        body(Item(parent: parent, name: name, path: path, info: info, opened: fd))
        guard let fd else { return }
        for child in names(in: fd) {
            visit(child, in: fd, at: path == "." ? child : path + "/" + child, volume: volume, body)
        }
    }

    // MARK: - Removing

    /// Removes the item `name` of the open folder `parent`, with all that is in it when it is
    /// a folder (`itself` false leaves the folder, emptied). What keeps an item from being
    /// deleted is taken off it first: a lock, an ACL, a folder its owner may not write to. A
    /// link is removed and not followed, and a folder of another volume is not gone into.
    /// `path` is what to call the item in `left`, which takes what could not be removed.
    /// Returns whether all of it is gone.
    @discardableResult
    static func remove(_ name: String, in parent: Int32, at path: String, itself: Bool = true, left: inout Leftovers) -> Bool {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return errno == ENOENT }
        // Only a folder can be emptied; a link in its place is left alone.
        guard itself || info.st_mode & S_IFMT == S_IFDIR else { return false }
        return remove(name, in: parent, at: path, info, itself: itself, volume: info.st_dev, left: &left)
    }

    private static func remove(_ name: String, in parent: Int32, at path: String, _ info: stat, itself: Bool, volume: dev_t,
                               left: inout Leftovers) -> Bool {
        guard info.st_mode & S_IFMT == S_IFDIR else {
            if unlinkat(parent, name, 0) == 0 { return true }
            // A lock or its ACL holds it; without them, once more. A socket, a pipe or a device
            // has no descriptor, and both come off by name.
            let kind = info.st_mode & S_IFMT
            if let fd = descriptor(of: name, in: parent, matching: info, forcing: true) {
                unlock(fd, info)
                close(fd)
            } else if kind != S_IFREG, kind != S_IFLNK {
                if info.st_flags & locks != 0 { setFlags(info.st_flags & ~locks, of: name, in: parent) }
                removeACL(of: name, in: parent)
            }
            if unlinkat(parent, name, 0) == 0 { return true }
            left.add(path)
            return false
        }
        guard info.st_dev == volume, let fd = descriptor(of: name, in: parent, matching: info, forcing: true) else {
            left.add(path)
            return false
        }
        unlock(fd, info)
        if info.st_mode & 0o700 != 0o700 { fchmod(fd, (info.st_mode & 0o7777) | 0o700) }
        var emptied = true
        for child in names(in: fd) {
            var below = stat()
            guard fstatat(fd, child, &below, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            if !remove(child, in: fd, at: path + "/" + child, below, itself: true, volume: volume, left: &left) { emptied = false }
        }
        close(fd)
        // A folder that still holds something is not named itself: what it holds is, already.
        guard emptied else { return false }
        if !itself || unlinkat(parent, name, AT_REMOVEDIR) == 0 { return true }
        left.add(path)
        return false
    }

    /// Takes the lock and the ACL off an open item. The lock first: a locked item does not let
    /// go of its ACL either.
    private static func unlock(_ fd: Int32, _ info: stat) {
        if info.st_flags & locks != 0 { fchflags(fd, info.st_flags & ~locks) }
        if let none = acl_init(0) {
            acl_set_fd_np(fd, none, ACL_TYPE_EXTENDED)
            acl_free(UnsafeMutableRawPointer(none))
        }
    }
}

/// What could not be removed: how many items, and the first of them by path.
public struct Leftovers: Sendable, Equatable {
    public private(set) var count = 0
    public private(set) var paths: [String] = []
    public var isEmpty: Bool { count == 0 }

    public init() {}

    mutating func add(_ path: String) {
        count += 1
        if paths.count < 10 { paths.append(path) }
    }
}
