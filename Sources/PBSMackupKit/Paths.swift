import Foundation
import Security

/// Where the run tool and the app keep their files. In a development build `PBS_MACKUP_HOME`
/// moves everything under one folder, which the tests use.
public enum Paths {
    /// Nil in a release build: there nothing in the environment moves the configuration or
    /// stands in for the Keychain.
    static var override: URL? {
        #if DEBUG
        return ProcessInfo.processInfo.environment["PBS_MACKUP_HOME"].map { URL(fileURLWithPath: $0) }
        #else
        return nil
        #endif
    }
    /// The home folder as the user database has it. Foundation's answer follows the variable
    /// `CFFIXED_USER_HOME`, and nothing in the environment is to move the configuration.
    static let home: URL = {
        var user = passwd(), found: UnsafeMutablePointer<passwd>?
        var text = [CChar](repeating: 0, count: 4096)
        guard getpwuid_r(getuid(), &user, &text, text.count, &found) == 0, found != nil, let folder = user.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: String(cString: folder), isDirectory: true)
    }()

    public static var support: URL {
        override?.appendingPathComponent("support") ?? home.appendingPathComponent("Library/Application Support/pbs-mackup")
    }
    public static var cache: URL {
        override?.appendingPathComponent("cache") ?? home.appendingPathComponent("Library/Caches/pbs-mackup")
    }
    public static var config: URL { support.appendingPathComponent("config.json") }
    public static var state: URL { support.appendingPathComponent("state.json") }
    public static var logs: URL { support.appendingPathComponent("logs") }
    public static var lock: URL { cache.appendingPathComponent("run.lock") }
    /// A folder for what no other program is to read: the mounted APFS snapshot, which holds a
    /// copy of everything in the home folder, Mail and Messages included, the files a run
    /// restores to check them, a new key on its way into the Keychain, and the lists of the
    /// owner's file names that `index`, `sizes` and `changedFolders` are. The cache is open to
    /// every program of the user. An app signed by a developer has its group container
    /// instead, where macOS asks the owner before it lets another developer's program in. A
    /// development build has no such folder and uses the cache.
    public static var guarded: URL { groupContainer ?? cache }
    /// Where a run mounts its APFS snapshot.
    public static var mount: URL { guarded.appendingPathComponent("mnt") }
    /// The home folder the client is given in place of the owner's; see `Client.environment`.
    public static var clientHome: URL { guarded.appendingPathComponent("client") }
    /// What the app and the run tool last stored themselves, see `Seal`. In the group
    /// container no other program can rewrite it; a development build keeps it with its
    /// other files, where it only guards against accidents.
    public static var seal: URL { (groupContainer ?? support).appendingPathComponent("seal.json") }
    private static let groupContainer: URL? = Identity.team.map { team in
        let group = "\(team).\(Identity.bundleID)"
        // Apple says to ask macOS for the folder before using it. The answer is this one, but
        // it is not taken from there: Foundation's idea of the home folder can be moved.
        _ = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        return home.appendingPathComponent("Library/Group Containers/\(group)")
    }
    /// The names in the snapshots that were searched, one file each: every name in the home
    /// folder, so it is in `guarded`, as are the three other files below that hold names. The
    /// app reads this one and the sizes itself, from the same folder.
    public static var index: URL { guarded.appendingPathComponent("index") }
    /// How big the backed-up folders are, one file each, from the last time they were measured.
    public static var sizes: URL { guarded.appendingPathComponent("sizes") }
    /// Where a run leaves a file to see how far the change log has come; see `ChangeLog`. In
    /// the cache: the files are empty and their names say nothing.
    public static var changeMarker: URL { cache.appendingPathComponent("changes") }
    /// The settings manifest a run uploads as `settings.conf`, while the run lasts. It names
    /// the apps that open at login.
    public static var settingsManifest: URL { guarded.appendingPathComponent("settings.json") }
    /// The folders that changed since the last backup, for the client, while a run lasts.
    public static var changedFolders: URL { guarded.appendingPathComponent("changed-folders") }
    /// Files opened from a backup to look at; emptied when the Backups window closes and when
    /// the app quits or starts. In the cache, not in `guarded`: the program that opens such a
    /// file is another developer's.
    public static var preview: URL { cache.appendingPathComponent("preview") }

    /// Makes `index` or `sizes`. In the cache no backup took them; the guarded folder is part
    /// of the home folder, so they carry the mark that Time Machine and the client leave an
    /// item out by, or each backup would take the names of the one before it.
    static func createLeftOutOfBackups(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var folder = folder, values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }

    /// Versions up to 0.5.0 kept the index, the sizes, the changed folders and the settings
    /// manifest in the cache, where every program of the user could read the names in them.
    /// Removes what is left of them there. Nothing where the guarded folder is the cache.
    public static func removeNamesFromCache() { removeNames(from: cache, nowIn: guarded) }

    static func removeNames(from cache: URL, nowIn guarded: URL) {
        guard guarded.path != cache.path else { return }
        for item in [index, sizes, settingsManifest, changedFolders] {
            try? FileManager.default.removeItem(at: cache.appendingPathComponent(item.lastPathComponent))
        }
    }

    /// What Open Log opens for the log a run's record names. Any program of the user can
    /// rewrite the state file, and what it names there, an app or a script, would be started
    /// by that click. So only a log is opened: a file right in the logs folder, named as a run
    /// names its log, and not a link that leads elsewhere. For anything else it is the folder.
    public static func logToOpen(_ named: String?) -> URL {
        guard let named else { return logs }
        let file = URL(fileURLWithPath: named).resolvingSymlinksInPath()
        guard file.deletingLastPathComponent().path == logs.resolvingSymlinksInPath().path, file.pathExtension == "log",
              (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return logs }
        return file
    }

    /// Not the mount point: mounting the snapshot makes it, and where that is refused only the
    /// mount fails.
    public static func createFolders() throws {
        for folder in [support, cache, logs] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }
}

/// The app's bundle identifier, from which the other names are made: the run tool signs as
/// that plus `.tool`, which is also the Keychain service, the client as `.client`, and the
/// launchd jobs are `.scheduled`, `.manual` and `.helper`. The run tool sits
/// inside the app, so both read the identifier from the app's bundle and the build script is
/// the one place that names it. Outside a bundle (a development build, the tests) it is the
/// identifier the build script uses when none is given.
public enum Identity {
    /// The app that the program in `executable` belongs to: the bundle it is the program of,
    /// or, for the run tool in a bundle of its own inside the app (see `Scripts/bundle.sh`),
    /// the app around that bundle. Nil for a program that is in no bundle's `Contents/MacOS`.
    /// `executable` is the file itself, not a link to it.
    static func app(of executable: URL) -> URL? {
        let programs = executable.deletingLastPathComponent(), contents = programs.deletingLastPathComponent()
        var bundle = contents.deletingLastPathComponent()
        guard programs.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents", bundle.pathExtension == "app" else {
            return nil
        }
        // A bundle in a folder of another app's `Contents` belongs to that app.
        while true {
            let contents = bundle.deletingLastPathComponent().deletingLastPathComponent()
            let around = contents.deletingLastPathComponent()
            guard contents.lastPathComponent == "Contents", around.pathExtension == "app" else { return bundle }
            bundle = around
        }
    }

    /// The app this program is part of. The app's `Contents/MacOS/pbs-mackup-run` can be a
    /// link to the run tool in its own bundle, so the link is followed first.
    public static let app: URL? = Bundle.main.executableURL.flatMap { app(of: $0.resolvingSymlinksInPath()) }

    public static let bundleID: String = app.flatMap { Bundle(url: $0)?.bundleIdentifier } ?? "me.0x23.pbs-mackup"

    /// What the run tool is signed as.
    public static var toolIdentifier: String { bundleID + ".tool" }
    /// The launchd job that makes the scheduled backups.
    public static var scheduledLabel: String { bundleID + ".scheduled" }
    /// The launchd job for a backup the owner asked for. It is not a background job, so such a
    /// backup gets the fast cores and unthrottled disk and network.
    public static var manualLabel: String { bundleID + ".manual" }
    /// The launchd job, and the name of its service, through which the app asks the run tool
    /// for what needs the token or the key.
    public static var helperLabel: String { bundleID + ".helper" }
    public static var jobs: [String] { [scheduledLabel, manualLabel, helperLabel] }
    /// The launchd daemon, and its service, that restores a whole home folder as root. Only
    /// registered while the owner restores this Mac from a backup; see `RestoreService`.
    public static var restoreLabel: String { bundleID + ".restore" }
    /// The right in the authorization database that a restore of a home folder asks for. Its
    /// rule is that an administrator authenticates; an administrator can make it stricter.
    public static var restoreRight: String { bundleID + ".restore-home" }

    /// The Team ID of the developer who signed the running program, from its code signature.
    /// Nil for a program no developer signed, and in every development build, whatever runs it.
    public static let team: String? = {
        #if DEBUG
        return nil
        #else
        if case .team(let team) = Signature.own { return team }
        return nil
        #endif
    }()
}

/// Who signed a program, from its code signature. The run tool hands the token and the key only
/// to a client that its own developer signed; see `Client.start`.
enum Signature {
    enum Signer: Equatable {
        /// A developer, by Team ID.
        case team(String)
        /// No developer: a build that is only signed ad hoc.
        case nobody
        /// Not to be found out: what runs is no longer what is on disk, or is Apple's own.
        case unknown
    }

    static func requirement(_ text: String) -> SecRequirement? {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    /// What a program meets that the developer with this Team ID signed, as text.
    static func requirementText(team: String, identifier: String? = nil) -> String? {
        // Both become part of the requirement's text: letters and digits, in an identifier
        // also dots and dashes, or it is none.
        func plain(_ text: String, also: String = "") -> Bool {
            !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || also.contains($0)) }
        }
        guard plain(team), identifier.map({ plain($0, also: ".-") }) ?? true else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
            + (identifier.map { " and identifier \"\($0)\"" } ?? "")
    }

    /// What a program meets that the developer with this Team ID signed, and signed as
    /// `identifier` when one is given: the developer has signed more than one program, and
    /// each is trusted with something else.
    static func requirement(team: String, identifier: String? = nil) -> SecRequirement? {
        requirementText(team: team, identifier: identifier).flatMap(requirement)
    }

    /// Whether the program in `file` meets `requirement` and is as it was signed.
    static func isSigned(_ file: URL, as requirement: SecRequirement) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(file as CFURL, [], &code) == errSecSuccess, let code else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// The program that runs as `pid`; nil when there is no such process.
    static func running(_ pid: pid_t) -> SecCode? {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess else { return nil }
        return code
    }

    /// Whether a running program meets `requirement`. A file can be exchanged between the look
    /// at it and its start; this asks about what runs, which fails when it is not the file's.
    static func isSigned(_ code: SecCode, as requirement: SecRequirement) -> Bool {
        SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// The Team ID a signature on disk names; nil for one no developer made.
    static func team(in code: SecStaticCode) -> String? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess else { return nil }
        return (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    static func signer(of code: SecCode) -> Signer {
        // The file on disk names the team; only what runs can vouch for it.
        var onDisk: SecStaticCode?
        if SecCodeCopyStaticCode(code, [], &onDisk) == errSecSuccess, let onDisk, let team = team(in: onDisk),
           let requirement = requirement(team: team), isSigned(code, as: requirement) {
            return .team(team)
        }
        if let adHoc = requirement("! anchor apple generic"), isSigned(code, as: adHoc) { return .nobody }
        return .unknown
    }

    /// Who signed the running program.
    static let own: Signer = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return .unknown }
        return signer(of: code)
    }()
}
