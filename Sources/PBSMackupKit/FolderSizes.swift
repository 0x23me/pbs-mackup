import Darwin
import Foundation

/// How much room a folder and what is in it take on disk, to decide what to leave out of the
/// backup. Only sizes are read, never contents.
public struct FolderSizes: Codable, Equatable, Sendable {
    public struct Node: Codable, Equatable, Sendable {
        public var name: String
        public var isFolder: Bool
        /// Bytes on disk of this item and everything below it, as Finder and `du` count: a file
        /// with several names once, but a copy that shares its storage with the original in full.
        public var bytes: Int64
        /// Of `bytes`, what belongs to files whose storage was already counted elsewhere
        /// (copies made by APFS without duplicating the data). Only counted among what the
        /// backup does not leave out by itself, so `bytes - leftOut - shared` is what is new
        /// to a backup.
        public var shared: Int64
        /// Of `bytes`, what the backup leaves out by itself below this item.
        public var leftOut: Int64
        public var files: Int
        /// Set when the backup leaves this whole item out by itself.
        public var reason: Reason?
        /// What is at least `FolderSizes.smallest` big, largest first. The rest is only in `bytes`.
        public var children: [Node]

        public init(name: String, isFolder: Bool, bytes: Int64 = 0, shared: Int64 = 0, leftOut: Int64 = 0,
                    files: Int = 0, reason: Reason? = nil, children: [Node] = []) {
            self.name = name; self.isFolder = isFolder; self.bytes = bytes; self.shared = shared
            self.leftOut = leftOut; self.files = files; self.reason = reason; self.children = children
        }
    }

    public enum Reason: String, Codable, Sendable {
        /// One of `Config.defaultExcludes`.
        case always
        /// Marked as excluded from Time Machine, usually by the app the item belongs to.
        case timeMachine
        /// Another volume is mounted here.
        case otherVolume
        /// A folder that is only in iCloud.
        case cloudOnly
    }

    /// Folders with a name from `Suggestions.names`, summed over the whole tree.
    public struct NameTotal: Codable, Equatable, Sendable {
        public var count: Int
        public var bytes: Int64
    }

    /// The folder that was measured.
    public var path: String
    public var root: Node
    public var measured: Date
    /// Folders that could not be read.
    public var unreadable: Int
    /// What files that are only in iCloud would take when downloaded. They take nothing on
    /// disk and are not backed up.
    public var cloudOnly: Int64
    public var names: [String: NameTotal]

    /// Items smaller than this are not listed on their own.
    public static let smallest: Int64 = 16 << 20

    public static func file(for source: String) -> URL {
        Paths.sizes.appendingPathComponent(Config.archiveName(for: source) + ".json")
    }

    public static func load(for source: String) -> FolderSizes? {
        guard let data = try? Data(contentsOf: file(for: source)) else { return nil }
        return (try? JSONDecoder.iso8601.decode(FolderSizes.self, from: data)).flatMap { $0.path == source ? $0 : nil }
    }

    public func save() throws -> URL {
        let file = FolderSizes.file(for: path)
        try FileManager.default.createDirectory(at: Paths.sizes, withIntermediateDirectories: true)
        try JSONEncoder.iso8601.encode(self).write(to: file, options: .atomic)
        // Folder names are private; the file is the owner's alone.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    /// Measures `path`. Takes about as long as listing every file once.
    public static func measure(_ path: String, names: Set<String> = Suggestions.names,
                               smallest: Int64 = FolderSizes.smallest) throws -> FolderSizes {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw Client.Failure(description: "\(path) is not a folder that can be read.")
        }
        let scan = Scan(device: info.st_dev, names: names, smallest: smallest)
        defer { scan.buffer.deallocate() }
        var root = scan.folder(path, relative: "", name: path, included: true, countNames: true)
        root.reason = nil
        return FolderSizes(path: path, root: root, measured: Date(), unreadable: scan.unreadable,
                           cloudOnly: scan.cloudOnly, names: scan.totals)
    }
}

/// One pass over a tree with `getattrlistbulk`, which returns the attributes of a whole
/// directory in a few calls.
private final class Scan {
    let device: dev_t
    let names: Set<String>
    let smallest: Int64
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1 << 18, alignment: 8)
    var clones = Set<UInt64>()
    var links = Set<UInt64>()
    var unreadable = 0
    var cloudOnly: Int64 = 0
    var totals: [String: FolderSizes.NameTotal] = [:]

    private let alwaysNames = Set(Config.defaultExcludes.filter { !$0.contains("/") })
    private let alwaysPaths = Set(Config.defaultExcludes.filter { $0.hasPrefix("/") }.map { String($0.dropFirst()) })

    init(device: dev_t, names: Set<String>, smallest: Int64) {
        self.device = device
        self.names = names
        self.smallest = smallest
    }

    private struct Entry {
        var name = ""
        var type: UInt32 = 0
        var device: dev_t = 0
        var flags: UInt32 = 0
        var allocated: Int64 = 0
    }

    func folder(_ path: String, relative: String, name: String, included: Bool, countNames: Bool) -> FolderSizes.Node {
        var node = FolderSizes.Node(name: name, isFolder: true)
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { unreadable += 1; return node }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(
            ATTR_CMN_ERROR | ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FLAGS | ATTR_CMN_FILEID)
        // ATTR_FILE_TOTALSIZE is the logical size, ATTR_FILE_ALLOCSIZE the size on disk.
        request.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE)
        // More common attributes, which go into the fork field when FSOPT_ATTR_CMN_EXTENDED is set.
        request.forkattr = attrgroup_t(ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS)

        var folders: [Entry] = []
        var big: [Entry] = []
        while true {
            let count = getattrlistbulk(descriptor, &request, buffer, 1 << 18, UInt64(FSOPT_ATTR_CMN_EXTENDED))
            if count <= 0 { break }
            var entry = buffer
            for _ in 0..<count {
                // An entry is its length, the attributes it has, and then those in the order of their bits.
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                defer { entry += length }
                var at = entry + MemoryLayout<UInt32>.size
                func take<T>(_ type: T.Type) -> T {
                    defer { at += MemoryLayout<T>.size }
                    return at.loadUnaligned(as: T.self)
                }
                let returned = take(attribute_set_t.self)
                func has(_ group: attrgroup_t, _ attribute: Int32) -> Bool { group & attrgroup_t(attribute) != 0 }
                if has(returned.commonattr, ATTR_CMN_ERROR), take(UInt32.self) != 0 { continue }
                var found = Entry()
                var namePointer: UnsafeMutableRawPointer?
                if has(returned.commonattr, ATTR_CMN_NAME) {
                    // The name itself is further on: this far from where its reference stands.
                    namePointer = at + Int(at.loadUnaligned(as: attrreference_t.self).attr_dataoffset)
                    at += MemoryLayout<attrreference_t>.size
                }
                if has(returned.commonattr, ATTR_CMN_DEVID) { found.device = take(dev_t.self) }
                if has(returned.commonattr, ATTR_CMN_OBJTYPE) { found.type = take(UInt32.self) }
                if has(returned.commonattr, ATTR_CMN_FLAGS) { found.flags = take(UInt32.self) }
                var fileID: UInt64 = 0
                if has(returned.commonattr, ATTR_CMN_FILEID) { fileID = take(UInt64.self) }
                var linkCount: UInt32 = 1, logical: Int64 = 0
                if has(returned.fileattr, ATTR_FILE_LINKCOUNT) { linkCount = take(UInt32.self) }
                if has(returned.fileattr, ATTR_FILE_TOTALSIZE) { logical = take(Int64.self) }
                if has(returned.fileattr, ATTR_FILE_ALLOCSIZE) { found.allocated = take(Int64.self) }
                var cloneID: UInt64 = 0, extendedFlags: UInt64 = 0
                if has(returned.forkattr, ATTR_CMNEXT_CLONEID) { cloneID = take(UInt64.self) }
                if has(returned.forkattr, ATTR_CMNEXT_EXT_FLAGS) { extendedFlags = take(UInt64.self) }

                if found.type == VDIR.rawValue {
                    found.name = namePointer.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) } ?? ""
                    folders.append(found)
                    continue
                }
                if found.flags & UInt32(SF_DATALESS) != 0 { cloudOnly += logical }
                // A file with several names counts where it is met first.
                if linkCount > 1, !links.insert(fileID).inserted { continue }
                node.files += 1
                node.bytes += found.allocated
                if included, extendedFlags & UInt64(EF_MAY_SHARE_BLOCKS) != 0, cloneID != 0, !clones.insert(cloneID).inserted {
                    node.shared += found.allocated
                }
                if found.allocated >= smallest {
                    found.name = namePointer.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) } ?? ""
                    big.append(found)
                }
            }
        }
        close(descriptor)

        for file in big {
            var child = FolderSizes.Node(name: file.name, isFolder: false, bytes: file.allocated, files: 1)
            if alwaysNames.contains(file.name) || markedForTimeMachine(path + "/" + file.name) {
                child.reason = alwaysNames.contains(file.name) ? .always : .timeMachine
                child.leftOut = file.allocated
                node.leftOut += file.allocated
            }
            node.children.append(child)
        }
        for found in folders {
            let childPath = path + "/" + found.name
            let childRelative = relative.isEmpty ? found.name : relative + "/" + found.name
            var child: FolderSizes.Node
            if found.device != device {
                child = .init(name: found.name, isFolder: true, reason: .otherVolume)
            } else if found.flags & UInt32(SF_DATALESS) != 0 {
                // Listing it would make macOS download it.
                child = .init(name: found.name, isFolder: true, reason: .cloudOnly)
            } else {
                var reason: FolderSizes.Reason?
                if alwaysNames.contains(found.name) || alwaysPaths.contains(childRelative) {
                    reason = .always
                } else if markedForTimeMachine(childPath) {
                    reason = .timeMachine
                }
                let named = countNames && reason == nil && names.contains(found.name)
                child = folder(childPath, relative: childRelative, name: found.name, included: included && reason == nil,
                               countNames: countNames && reason == nil && !named)
                child.reason = reason
                if reason != nil {
                    child.leftOut = child.bytes
                } else if named {
                    totals[found.name, default: .init(count: 0, bytes: 0)].count += 1
                    totals[found.name]!.bytes += child.bytes - child.leftOut
                }
            }
            node.bytes += child.bytes
            node.shared += child.shared
            node.leftOut += child.leftOut
            node.files += child.files
            if child.bytes >= smallest || child.reason == .otherVolume || child.reason == .cloudOnly {
                node.children.append(child)
            }
        }
        node.children.sort { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }
        return node
    }

    private func markedForTimeMachine(_ path: String) -> Bool {
        getxattr(path, SampleCheck.timeMachineExclusion, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }
}
