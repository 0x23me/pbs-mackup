import Darwin
import Foundation

// <membership.h>, declared here because not every SDK has `Darwin` show it (the one on the macos-26
// runner does not); the system library has them all the same.
@_silgen_name("mbr_uid_to_uuid")
private func membershipUUID(ofUID uid: uid_t, _ uuid: UnsafeMutablePointer<UInt8>) -> Int32
@_silgen_name("mbr_uuid_to_id")
private func membershipID(ofUUID uuid: UnsafePointer<UInt8>, _ id: UnsafeMutablePointer<id_t>, _ kind: UnsafeMutablePointer<Int32>) -> Int32

/// Puts a whole home folder back on a Mac that was set up anew: what `pbs-mackup-run
/// restore-home` does, from the account of another administrator, and what the restore daemon
/// does for the app (`RestoreService`), while the user whose folder it is stays logged in.
/// Root does it. The folder is restored on the volume of the user's new one, so that owners,
/// permissions, ACLs and flags come back as they were, and only once it is complete do the two
/// change places. The new one is kept, under another name.
///
/// The restored folder belongs to the user from its first file on, and root still has work to
/// do in it. So it is restored inside a folder that only root can enter (`Places.staging`) and
/// comes out of there only at the swap; and what root does in it goes by descriptors and never
/// by a path (`Tree`), which holds whoever owns the folders on the way.
public enum HomeRestore {
    /// A user of this Mac, as the restore needs it.
    public struct Account {
        public let name: String
        public let uid: uid_t
        public let home: URL
    }

    /// Where a restore of the home folder `home` works.
    public struct Places: Equatable, Sendable {
        public let home: URL
        /// A folder next to `home` that belongs to root and that nobody else can enter. Next
        /// to it, so that it is on the same volume and the swap stays a rename.
        public let staging: URL
        /// The restored folder, in `staging` until it takes the place of `home`.
        public let restored: URL
        /// Where the folder that was at `home` is kept after the swap, for its owner to look
        /// into until they have it deleted.
        public let aside: URL

        public init(home: URL) {
            let home = home.standardizedFileURL
            self.home = home
            staging = home.deletingLastPathComponent().appendingPathComponent(".pbs-mackup-restore-\(home.lastPathComponent)")
            restored = staging.appendingPathComponent(home.lastPathComponent)
            aside = URL(fileURLWithPath: home.path + ".before-restore")
        }
    }

    /// What has to hold before anything is restored: no restore that did not finish is in the
    /// way, and the disk has room for the snapshot.
    public static func preflight(_ places: Places, size: Int64?) throws {
        if exists(places.staging) { try checkStaging(places.staging) }
        guard !exists(places.restored) else {
            throw Failure(description: "\(places.restored.path) is there already, from an earlier restore that did not finish. "
                + "Remove \(places.staging.path) first, as root.")
        }
        guard !exists(places.aside) else {
            throw Failure(description: "\(places.aside.path) is there already, from an earlier restore. Move it out of the way first.")
        }
        if let size, let free = freeBytes(at: places.home.deletingLastPathComponent()), free < size + size / 10 {
            throw Failure(description: "The snapshot takes \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)), "
                + "and the disk has \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free.")
        }
    }

    /// Makes the folder a restore works in, or takes the one an earlier restore left when it
    /// is as this would make it.
    static func makeStaging(_ folder: URL) throws {
        let made = mkdir(folder.path, 0o700) == 0
        guard made || errno == EEXIST else {
            throw Failure(description: "\(folder.path) could not be made: \(String(cString: strerror(errno))).")
        }
        try checkStaging(folder, made: made)
    }

    /// Throws unless `folder` is a folder of whoever runs this, which is root, that nobody else
    /// can enter: mode 700 and no ACL. One that was just `made` has that seen to; one that was
    /// there is only looked at, and not trusted when someone made it otherwise.
    static func checkStaging(_ folder: URL, made: Bool = false) throws {
        let refused = Failure(description: "\(folder.path) is not a folder that only \(geteuid() == 0 ? "root" : "its owner") can open. "
            + "Remove it, then restore again.")
        guard let fd = Tree.open(folder.path) else { throw refused }
        defer { close(fd) }
        if made {
            // What the folder above hands down, and what the umask took away.
            if let none = acl_init(0) {
                acl_set_fd_np(fd, none, ACL_TYPE_EXTENDED)
                acl_free(UnsafeMutableRawPointer(none))
            }
            fchmod(fd, 0o700)
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700 else { throw refused }
        var named = false
        forEachQualifier(fd) { _, _ in named = true; return true }
        if named { throw refused }
    }

    /// Removes what a restore that does not go on left: the restored folder and the folder it
    /// is in. A folder that is not root's alone is not this program's and stays.
    public static func discard(_ places: Places) {
        guard (try? checkStaging(places.staging)) != nil else { return }
        removeRestored(places.staging)
    }

    public static func account(_ name: String) throws -> Account {
        guard let entry = getpwnam(name) else {
            throw Failure(description: "This Mac has no user “\(name)”. Make the account first, with the short name it had on the old Mac.")
        }
        let home = URL(fileURLWithPath: String(cString: entry.pointee.pw_dir))
        guard home.path.hasPrefix("/Users/"), home.pathComponents.count == 3 else {
            throw Failure(description: "\(name)'s home folder is \(home.path), not a folder in /Users.")
        }
        return Account(name: name, uid: entry.pointee.pw_uid, home: home)
    }

    /// Whether any program runs as `uid`: a user who is logged in, also one the Mac only
    /// switched away from, has dozens.
    public static func hasPrograms(uid: uid_t) -> Bool { !programs(uid: uid).isEmpty }

    /// The process ids of the programs that run as `uid`.
    static func programs(uid: uid_t) -> [pid_t] {
        var request: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: uid)]
        var size = 0
        guard sysctl(&request, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var found = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 8)
        size = found.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&request, 4, &found, &size, nil, 0) == 0 else { return [] }
        return found.prefix(size / MemoryLayout<kinfo_proc>.stride).map(\.kp_proc.p_pid)
    }

    /// The snapshot to restore: `requested` when given, otherwise the newest that holds
    /// `archive`, from the group `host/<from>` or, without `from`, from the one group that has
    /// such an archive. Two Macs with a home folder of the same name are not told apart by guessing.
    public static func choose(from snapshots: [Client.Snapshot], archive: String, requested: String?, group from: String?) throws -> Client.Snapshot {
        if let requested {
            guard let snapshot = snapshots.first(where: { $0.name == requested }) else {
                throw Failure(description: "The namespace has no snapshot \(requested).")
            }
            guard snapshot.archives.contains(archive) else {
                throw Failure(description: "\(requested) has no \(archive); it has \(snapshot.archives.joined(separator: ", ")).")
            }
            return snapshot
        }
        let holding = snapshots.filter { $0.archives.contains(archive) && (from == nil || group(of: $0.name) == "host/\(from!)") }
        guard let newest = holding.max(by: { $0.time < $1.time }) else {
            let seen = Set(snapshots.flatMap(\.archives)).sorted()
            throw Failure(description: "No snapshot\(from.map { " of host/\($0)" } ?? "") holds \(archive)."
                + (seen.isEmpty ? "" : " The archives there: \(seen.joined(separator: ", ")). Name one with --archive."))
        }
        let groups = Set(holding.map { group(of: $0.name) }).sorted()
        guard groups.count == 1 else {
            throw Failure(description: "Backups of more than one Mac hold \(archive): \(groups.joined(separator: ", ")). Say which with --from, as in --from \(groups[0].dropFirst(5)).")
        }
        return newest
    }

    /// `host/<id>` of `host/<id>/<time>`.
    static func group(of snapshot: String) -> String {
        snapshot.split(separator: "/").prefix(2).joined(separator: "/")
    }

    /// Bytes free on the volume of `url`.
    public static func freeBytes(at url: URL) -> Int64? {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return nil }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }

    /// Restores `archive` of `snapshot` as `places.restored`, which must not exist yet, handing
    /// what the client says to `output` as it comes. A restore that fails leaves nothing behind.
    public static func restore(_ client: Client, snapshot: String, archive: String, into places: Places,
                               output: (Data) -> Void) throws {
        try Client.check(snapshot: snapshot, archives: [archive])
        let folder = places.restored
        try makeStaging(places.staging)
        guard !exists(folder) else { throw Failure(description: "\(folder.path) is there already, from an earlier try. Remove it first.") }
        do {
            let result = try client.start(["restore", snapshot, archive, folder.path], mergingErrors: true).finish(output: output)
            guard result.status == 0 else {
                throw Failure(description: "The client could not restore \(archive) (exit status \(result.status)); nothing was changed.")
            }
            guard exists(folder) else { throw Failure(description: "The client restored nothing into \(folder.path).") }
        } catch {
            discard(places)
            throw error
        }
    }

    /// Hands what belongs to `old` below `root` to `new`, for a user whose number on this Mac is
    /// not the one it had. Returns how many items changed and the ones that could not.
    public static func reown(_ root: URL, from old: uid_t, to new: uid_t) -> (changed: Int, failed: [String]) {
        var changed = 0, failed: [String] = []
        let group = gid_t(bitPattern: -1)
        Tree.walk(root) { item in
            guard item.info.st_uid == old else { return }
            // By its descriptor the item is the one that was just seen to belong to `old`. A
            // socket, a pipe or a device has none and goes by its name in the open folder.
            let done = item.isSpecial
                ? fchownat(item.parent, item.name, new, group, AT_SYMLINK_NOFOLLOW) == 0
                : item.withDescriptor { fd in unlocked(fd, item.info) { fchown(fd, new, group) == 0 } } ?? false
            if done { changed += 1 } else { failed.append(item.path) }
        }
        return (changed, failed)
    }

    /// The ids named in ACLs below `root` that are nobody on this Mac. In a home folder from
    /// another Mac that is its owner as that Mac knew them: macOS names a user in an ACL by an
    /// id of its own (the GeneratedUID), which a new account gets anew. A home folder's own
    /// ACLs name only the group everyone, which every Mac knows; `Public/Drop Box` names its owner.
    public static func strangers(in root: URL) -> Set<UUID> {
        var found: Set<UUID> = []
        Tree.walk(root) { item in
            item.withDescriptor { fd in
                forEachQualifier(fd) { id, _ in
                    if !isKnown(id) { found.insert(id) }
                    return false
                }
            }
        }
        return found
    }

    /// Puts `new` in the place of `old` in every ACL below `root`.
    public static func replaceInACLs(_ root: URL, _ old: UUID, with new: UUID) -> (changed: Int, failed: [String]) {
        var changed = 0, failed: [String] = []
        Tree.walk(root) { item in
            item.withDescriptor { fd in
                guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { return }
                defer { acl_free(UnsafeMutableRawPointer(acl)) }
                var touched = false
                forEachEntry(acl) { entry in
                    guard let qualifier = acl_get_qualifier(entry) else { return }
                    defer { acl_free(qualifier) }
                    let guid = qualifier.assumingMemoryBound(to: guid_t.self)
                    guard UUID(uuid: guid.pointee.g_guid) == old else { return }
                    var replacement = guid_t(g_guid: new.uuid)
                    if acl_set_qualifier(entry, &replacement) == 0 { touched = true }
                }
                guard touched else { return }
                if unlocked(fd, item.info, { acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0 }) { changed += 1 } else { failed.append(item.path) }
            }
        }
        return (changed, failed)
    }

    /// The GeneratedUID of a user of this Mac.
    public static func generatedUID(of uid: uid_t) -> UUID? {
        var id = UUID().uuid
        let status = withUnsafeMutableBytes(of: &id) { membershipUUID(ofUID: uid, $0.baseAddress!.assumingMemoryBound(to: UInt8.self)) }
        return status == 0 ? UUID(uuid: id) : nil
    }

    /// What a restore leaves out of a home folder: the files of iCloud Drive and of the other
    /// cloud storage providers, and what macOS knows about their state. Their contents are in
    /// the cloud and come back once the owner signs in again; an old copy next to an old state
    /// would leave the provider to sort out which side is right.
    public static let cloudFolders = ["Library/Mobile Documents", "Library/CloudStorage", "Library/Application Support/CloudDocs",
                                      "Library/Application Support/FileProvider",
                                      "Library/Containers/com.apple.CloudDocs.iCloudDriveFileProvider",
                                      "Library/Containers/com.apple.CloudDocs.iCloudDriveFileProviderManaged"]

    /// What follows the restore and comes before the swap: the owner of this Mac in place of
    /// the old one, in owners and ACLs, and the cloud folders taken out. Returns what was done,
    /// as sentences for the owner.
    public static func adapt(_ restored: URL, to account: Account) -> [String] {
        var notes: [String] = []
        var info = stat()
        if lstat(restored.path, &info) == 0, info.st_uid != account.uid {
            let reowned = reown(restored, from: info.st_uid, to: account.uid)
            notes.append("\(reowned.changed.formatted()) files are now owned by your account on this Mac (uid \(info.st_uid) on the old Mac, \(account.uid) here).")
            if !reowned.failed.isEmpty { notes.append("These still belong to uid \(info.st_uid): \(reowned.failed.prefix(10).joined(separator: ", "))") }
        }
        let strangers = strangers(in: restored)
        if strangers.count == 1, let old = strangers.first, let new = generatedUID(of: account.uid) {
            let replaced = replaceInACLs(restored, old, with: new)
            notes.append("Sharing permissions that named you on the old Mac now name your account here (\(replaced.changed) \(replaced.changed == 1 ? "item" : "items")).")
            if !replaced.failed.isEmpty { notes.append("These ACLs could not be changed: \(replaced.failed.prefix(10).joined(separator: ", "))") }
        } else if strangers.count > 1 {
            notes.append("ACLs name \(strangers.count) users or groups this Mac does not know; they were left as they are.")
        }
        if removeCloudFolders(from: restored) {
            notes.append("iCloud Drive and other cloud storage were left out. They sync again once you sign in.")
        }
        return notes
    }

    /// Removes `cloudFolders` from a restored home folder; returns whether any was there. Each
    /// is reached from the folder itself, name by name and never through a link: a backup can
    /// hold a link where `Library` should be, and what that points to is not the restore's.
    static func removeCloudFolders(from restored: URL) -> Bool {
        guard let root = Tree.open(restored.path) else { return false }
        defer { close(root) }
        var found = false
        for folder in cloudFolders {
            let names = folder.split(separator: "/").map(String.init)
            guard let name = names.last, let parent = Tree.open(Array(names.dropLast()), below: root) else { continue }
            defer { close(parent) }
            var info = stat(), left = Leftovers()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            Tree.remove(name, in: parent, at: folder, left: &left)
            found = true
        }
        return found
    }

    /// Deletes what is in the home folder that a restore set aside, for the app at Finish. It
    /// is the work of the folder's owner and done as them, not by the restore daemon: the
    /// owner can reach that folder all the while, and root deleting in a folder that someone
    /// else can change is how root gets sent to files that are not theirs. What the owner
    /// cannot delete stays and is returned. So does the emptied folder itself: it lies in
    /// /Users, where only root removes it, which the daemon does when it is told to finish.
    public static func emptyAside(of state: RestoreState) -> Leftovers {
        guard state.phase == .done, state.uid == getuid() else { return Leftovers() }
        return empty(URL(fileURLWithPath: state.aside))
    }

    /// Removes what is in `folder` and leaves the folder.
    static func empty(_ folder: URL) -> Leftovers {
        var left = Leftovers()
        guard let (parent, name) = Tree.parent(of: folder) else { return left }
        defer { close(parent) }
        Tree.remove(name, in: parent, at: folder.path, itself: false, left: &left)
        return left
    }

    /// Whether `name` has a login session: at the Mac, also one it only switched away from, or
    /// over the network.
    public static func isLoggedIn(_ name: String) -> Bool {
        setutxent()
        defer { endutxent() }
        while let entry = getutxent() {
            guard entry.pointee.ut_type == USER_PROCESS else { continue }
            let user = withUnsafeBytes(of: entry.pointee.ut_user) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if user == name { return true }
        }
        return false
    }

    /// Ends what macOS keeps running for a user after they logged out: their launchd domain
    /// with its background services, some of which keep files in the home folder open (the
    /// Messages database, for one), and then whatever still runs as them outside it, such as
    /// system services that work for the user (`languageassetd`): asked to quit, and made to
    /// after five seconds. Only called once the user has no login session. Returns whether no
    /// program of theirs is left.
    public static func endBackgroundSession(uid: uid_t) -> Bool {
        tool("/bin/launchctl", ["bootout", "user/\(uid)"])
        if waitUntilGone(uid: uid, seconds: 10) { return true }
        for signal in [SIGTERM, SIGKILL] {
            programs(uid: uid).forEach { kill($0, signal) }
            if waitUntilGone(uid: uid, seconds: 5) { return true }
        }
        return false
    }

    private static func waitUntilGone(uid: uid_t, seconds: Int) -> Bool {
        for _ in 0..<(seconds * 4) {
            if !hasPrograms(uid: uid) { return true }
            usleep(250_000)
        }
        return !hasPrograms(uid: uid)
    }

    /// Lets the restored folder take the place of the home folder, which moves to `aside`. When
    /// the second step fails the first is undone. The folder the restore worked in is empty
    /// after and goes.
    public static func swap(_ places: Places) throws {
        let (home, restored, aside) = (places.home, places.restored, places.aside)
        // What is in a folder that others could get into is not known to be what was restored.
        try checkStaging(places.staging)
        guard exists(restored) else { throw Failure(description: "The restored folder is no longer at \(restored.path).") }
        guard !exists(aside) else { throw Failure(description: "\(aside.path) is there already. Move it out of the way first.") }
        let hadHome = exists(home)
        if hadHome, rename(home.path, aside.path) != 0 {
            throw Failure(description: "\(home.path) could not be moved aside: \(String(cString: strerror(errno)))."
                + (errno == EPERM ? " Give Terminal Full Disk Access in System Settings and run the command again." : ""))
        }
        if rename(restored.path, home.path) != 0 {
            let reason = String(cString: strerror(errno))
            if hadHome { rename(aside.path, home.path) }
            throw Failure(description: "The restored folder could not take the place of \(home.path): \(reason). It is still at \(restored.path).")
        }
        rmdir(places.staging.path)
    }

    // MARK: - Owners and ACLs

    /// Runs `change` with Finder's lock off the open item, which keeps even root from changing
    /// its owner or ACL, and puts the lock back after.
    static func unlocked(_ fd: Int32, _ info: stat, _ change: () -> Bool) -> Bool {
        let locked = info.st_flags & Tree.locks != 0
        if locked { fchflags(fd, info.st_flags & ~Tree.locks) }
        defer { if locked { fchflags(fd, info.st_flags) } }
        return change()
    }

    static func forEachEntry(_ acl: acl_t, _ body: (acl_entry_t) -> Void) {
        var entry: acl_entry_t?
        var which = ACL_FIRST_ENTRY.rawValue
        while acl_get_entry(acl, which, &entry) == 0, let current = entry {
            which = ACL_NEXT_ENTRY.rawValue
            body(current)
        }
    }

    /// Calls `body` with the id each ACL entry of the open item names, until it returns true.
    static func forEachQualifier(_ fd: Int32, _ body: (UUID, acl_entry_t) -> Bool) {
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { return }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var stop = false
        forEachEntry(acl) { entry in
            guard !stop, let qualifier = acl_get_qualifier(entry) else { return }
            defer { acl_free(qualifier) }
            stop = body(UUID(uuid: qualifier.assumingMemoryBound(to: guid_t.self).pointee.g_guid), entry)
        }
    }

    /// Whether this Mac knows the user or group `id` stands for.
    static func isKnown(_ id: UUID) -> Bool {
        var uuid = id.uuid, found = id_t(), kind: Int32 = 0
        return withUnsafeBytes(of: &uuid) { membershipID(ofUUID: $0.baseAddress!.assumingMemoryBound(to: UInt8.self), &found, &kind) } == 0
    }
}
