import CryptoKit
import Darwin
import Foundation

/// One backup run: skip checks, frozen snapshot, client, cleanup, record.
public final class Runner {
    public enum Exit: Int32 { case done = 0, failed = 1, notConfigured = 2, alreadyRunning = 3 }

    private let config: Config
    private let trigger: Trigger
    /// Read every folder instead of only those the change log names.
    private let readEverything: Bool
    private var state: State
    private let start = Date()
    private var logHandle: FileHandle?
    private var logURL: URL?
    private let lock = NSLock()
    private var cancelled = false
    private var child: Process?

    public init(config: Config, trigger: Trigger, readEverything: Bool = false) {
        self.config = config
        self.trigger = trigger
        self.readEverything = readEverything
        self.state = State.load()
    }

    /// Asks the run to stop. Safe to call from a signal handler queue.
    public func cancel() {
        lock.lock()
        cancelled = true
        let process = child
        lock.unlock()
        process?.interrupt()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public func run() -> Exit {
        do { try Paths.createFolders() } catch { print("cannot create folders: \(error)"); return .failed }

        // One run at a time.
        let lockFD = open(Paths.lock.path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            print("a backup is already running")
            return .alreadyRunning
        }
        defer { close(lockFD) }

        state = State.load()
        stopOrphanedClient()
        removeLeftovers()
        if state.paused && trigger == .scheduled {
            print("automatic backups are paused")
            return .done
        }
        // launchd starts the tool every few minutes; it runs when the owner's interval is over.
        if trigger == .scheduled, !Runner.isDue(last: state.last?.start, intervalMinutes: config.interval, now: start) {
            print("the next backup is not due yet")
            return .done
        }

        if let reason = skipReason() {
            return finish(.skipped, reason: reason, step: nil, frozen: false, output: ClientOutput())
        }
        let client: Client
        do { client = try Client(config: config) } catch {
            _ = finish(.failed, reason: "\(error)", step: "setup", frozen: false, output: ClientOutput())
            return .notConfigured
        }

        openLog()
        state.running = Running(pid: getpid(), start: start, trigger: trigger,
                                progress: Progress(step: "preparing", updated: Date()))
        save()
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .background], reason: "Backup to Proxmox Backup Server")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        // Where the change log is now, before the snapshot: whatever is in the snapshot and
        // not in the log up to here will be in the log after it, for the next run to find.
        let position = config.sources.first.flatMap { ChangeLog.position(of: realPath($0)) }

        // Frozen view: snapshot, note its date, then mount.
        var root = ""
        var frozen = false
        do {
            let date = try LocalSnapshot.create()
            state.localSnapshot = date
            save()
            log("local snapshot \(date)")
            do {
                try LocalSnapshot.mount(date, at: Paths.mount)
                root = Paths.mount.path
                frozen = true
            } catch {
                LocalSnapshot.delete(date)
                state.localSnapshot = nil
                save()
                guard config.frozenSnapshot == .whenPermitted else { throw error }
                log("snapshot could not be mounted (\(error)); reading the live folders instead")
            }
        } catch {
            return finish(.failed, reason: "\(error)", step: "snapshot", frozen: false, output: ClientOutput())
        }
        defer { removeLeftovers() }

        let settings = settingsDigest(client: client)
        let plan = changedFolders(root: root, settings: settings, client: client)
        log(plan.note)
        defer { try? FileManager.default.removeItem(at: Paths.changedFolders) }

        var output = ClientOutput()
        let status = backup(root: root, client: client, changed: plan.base, output: &output)
        changes = output.result.changeList.flatMap { $0.hasPrefix("ignored") ? "everything read: the client \($0)" : nil } ?? plan.note
        if isCancelled {
            return finish(.cancelled, reason: nil, step: nil, frozen: frozen, output: output)
        }
        // The position belongs to the snapshot this run read from, so it is only a basis
        // together with the backup made from it. A run that fails keeps the earlier basis;
        // the client checks that the backup it builds on is that one.
        if status == 0, let position, let snapshot = output.snapshot {
            state.changeBase = ChangeBase(position: position, snapshot: snapshot, settings: settings)
        }
        guard status == 0 else {
            return finish(.failed, reason: output.result.error ?? "The client exited with status \(status).",
                          step: "backup", frozen: frozen, output: output)
        }

        state.running?.progress = Progress(step: "checking", updated: Date())
        save()
        let check = checkSample(client: client, snapshot: output.snapshot, root: root)
        state.running?.progress = Progress(step: "cleaning up", updated: Date())
        save()
        guard check.mismatches.isEmpty else {
            let named = check.mismatches.prefix(5).joined(separator: "; ") + (check.mismatches.count > 5 ? "; …" : "")
            return finish(.failed, reason: "\(check.mismatches.count) of \(check.checked) files restored as a check differ from what was backed up: \(named)",
                          step: "verify", frozen: frozen, output: output, check: check)
        }
        return finish(.success, reason: nil, step: nil, frozen: frozen, output: output, check: check)
    }

    /// Restores a few files from the new snapshot and compares each with what was backed up.
    private func checkSample(client: Client, snapshot: String?, root: String) -> (checked: Int, mismatches: [String]) {
        let count = config.sampleFiles ?? 20
        guard let snapshot, count > 0, !config.sources.isEmpty else { return (0, []) }
        let staging = Paths.cache.appendingPathComponent("check-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer {
            // Each restored item sits in a folder that got the metadata of the archive's root,
            // possibly with an ACL that forbids deleting it.
            tool("/bin/chmod", ["-R", "-N", staging.path])
            try? FileManager.default.removeItem(at: staging)
        }
        var checked = 0
        var mismatches: [String] = []
        let share = max(1, count / config.sources.count)
        for source in config.sources {
            let path = realPath(source)
            let folder = URL(fileURLWithPath: root + path)
            for relative in SampleCheck.pick(in: folder, count: share, maxBytes: 200_000_000 / Int64(config.sources.count)) {
                if isCancelled { return (checked, mismatches) }
                let original = folder.appendingPathComponent(relative)
                // Reading the live folders: a file changed since the run began proves nothing.
                if root.isEmpty, let modified = try? original.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   modified >= start { continue }
                let target = staging.appendingPathComponent("\(checked)")
                do {
                    _ = try client.capture(["catalog", "extract", snapshot, Config.archiveName(for: path), relative, target.path])
                } catch {
                    // With exclusion patterns a picked file may rightly be absent from the snapshot.
                    if "\(error)".contains("no such path"), !config.excludes.isEmpty { continue }
                    checked += 1
                    mismatches.append("\(relative) (cannot be restored: \(error))")
                    continue
                }
                checked += 1
                let differences = SampleCheck.differences(original: original, restored: target.appendingPathComponent(original.lastPathComponent))
                if !differences.isEmpty { mismatches.append("\(relative) (\(differences.joined(separator: ", ")))") }
                log("checked \(relative): \(differences.isEmpty ? "identical" : differences.joined(separator: ", "))")
            }
        }
        return (checked, mismatches)
    }

    /// The real path of a source: inside the snapshot there is no /var or /tmp link, only /private/var.
    private func realPath(_ source: String) -> String {
        let expanded = (source as NSString).expandingTildeInPath
        return realpath(expanded, nil).map { pointer -> String in defer { free(pointer) }; return String(cString: pointer) } ?? expanded
    }

    // MARK: - Changes

    private var changes: String?

    static func isDue(last: Date?, intervalMinutes: Int, now: Date) -> Bool {
        // Half a minute of slack: launchd's timer is not exact.
        guard let last else { return true }
        return now.timeIntervalSince(last) >= Double(intervalMinutes * 60) - 30
    }

    /// What decides the content of a backup besides the files: when any of it changes,
    /// folders taken over from the previous backup could be wrong.
    private func settingsDigest(client: Client) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: client.executable.path)
        let parts = config.sources.map(realPath) + ["--"] + Config.defaultExcludes + config.excludes
            + ["--", client.executable.path, "\(attributes?[.size] ?? 0)", "\(attributes?[.modificationDate] ?? 0)"]
        return SHA256.hash(data: Data(parts.joined(separator: "\u{0}").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Asks the change log which folders changed since the last successful run and writes
    /// them where the client reads them. `base` is the backup time the list is relative to;
    /// nil means: read everything, and `note` says why.
    private func changedFolders(root: String, settings: String, client: Client) -> (base: String?, note: String) {
        if readEverything { return (nil, "everything read: asked to") }
        guard let base = state.changeBase else { return (nil, "everything read: no earlier backup to build on") }
        guard base.settings == settings else { return (nil, "everything read: folders, exclusions or the client changed") }
        // An older client knows nothing of such a list; its help says what it takes.
        guard tool(client.executable.path, ["backup", "--help"]).output.contains("--changed-dirs") else {
            return (nil, "everything read: this client cannot take a list of changes")
        }
        guard let time = base.snapshot.split(separator: "/").last else { return (nil, "everything read: no earlier backup to build on") }
        let roots = config.sources.map(realPath)
        switch ChangeLog.changes(below: roots, since: base.position, marker: Paths.changeMarker) {
        case .unusable(let reason):
            return (nil, "everything read: \(reason)")
        case .changes(let found):
            do {
                try found.records(prefix: root).write(to: Paths.changedFolders, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.changedFolders.path)
            } catch {
                return (nil, "everything read: \(error.localizedDescription)")
            }
            return (String(time), "\(found.folders.union(found.subtrees).count) changed folders read, the rest taken over from \(base.snapshot)")
        }
    }

    // MARK: - Steps

    /// A reason not to run at all, or nil.
    private func skipReason() -> String? {
        guard let server = config.server else { return nil }
        if !Reachability.canConnect(host: server.host, port: server.port, timeout: 5) {
            return "The server \(server.host) is not reachable."
        }
        return Runner.batterySkip(trigger: trigger, battery: Power.battery(),
                                  lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    /// A scheduled run waits when the Mac runs on battery below 20 % or in Low Power Mode; a run
    /// started by hand never does.
    static func batterySkip(trigger: Trigger, battery: (percent: Int, onAC: Bool)?, lowPowerMode: Bool) -> String? {
        guard trigger == .scheduled, let battery, !battery.onAC, battery.percent < 20 || lowPowerMode else { return nil }
        return "On battery (\(battery.percent) %)."
    }

    private func backup(root: String, client: Client, changed base: String?, output: inout ClientOutput) -> Int32 {
        var arguments = ["backup"]
        for source in config.sources {
            let path = realPath(source)
            arguments.append("\(Config.archiveName(for: path)):\(root)\(path)")
        }
        arguments += ["--backup-id", config.backupID, "--change-detection-mode=metadata", "--crypt-mode", "encrypt",
                      "--progress-json", "true", "--skip-placeholders", "true", "--skip-tm-excluded", "true"]
        for pattern in Config.defaultExcludes + config.excludes { arguments += ["--exclude", pattern] }
        if let base { arguments += ["--changed-dirs", Paths.changedFolders.path, "--changed-dirs-base", base] }
        log("client: \(client.executable.path) \(arguments.joined(separator: " "))")

        let process = client.process(arguments)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try client.start(process) } catch {
            output.read("Error: cannot start the client: \(error.localizedDescription)")
            return -1
        }
        lock.lock(); child = process; lock.unlock()
        if isCancelled { process.interrupt() }
        state.running?.clientPID = process.processIdentifier
        state.running?.progress = Progress(step: "backing up", updated: Date())
        save()
        var pending = Data()
        var upload = UploadSpeed()
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...newline)
                // Progress records arrive every second and go to the state file, not the log.
                guard output.read(line) else { log(line); continue }
                if let progress = output.progress {
                    let bytes = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                    let seconds = Int(progress.elapsed)
                    let expected = state.lastSuccess?.result.bytesProcessed
                    // What went over the network; an older client only says how much data that was.
                    let speed = upload.add(bytes: progress.bytesSent ?? progress.bytesUploaded, at: progress.elapsed)
                    state.running?.progress = Progress(
                        step: "backing up", processed: bytes(progress.bytesProcessed), uploaded: bytes(progress.bytesUploaded),
                        elapsed: seconds < 90 ? "\(seconds) s" : "\(seconds / 60) min", entries: progress.entries,
                        bytesProcessed: progress.bytesProcessed, bytesUploaded: progress.bytesUploaded,
                        speed: speed.flatMap(UploadSpeed.text), bitsPerSecond: speed,
                        expectedBytes: expected, path: progress.path, updated: Date())
                    save()
                }
            }
        }
        process.waitUntilExit()
        lock.lock(); child = nil; lock.unlock()
        return process.terminationStatus
    }

    /// Stops the client of an earlier run whose run tool died: it would keep the backup group
    /// locked on the server and the snapshot mounted.
    private func stopOrphanedClient() {
        guard let stale = state.running else { return }
        if let pid = stale.clientPID, pid != getpid() {
            var buffer = [CChar](repeating: 0, count: 4096)   // PROC_PIDPATHINFO_MAXSIZE
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            // Only if that process id still is a client: ids are reused.
            if length > 0, String(cString: buffer).hasSuffix("/proxmox-backup-client") {
                kill(pid, SIGTERM)
                for _ in 0..<50 where kill(pid, 0) == 0 { usleep(100_000) }
                if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            }
        }
        state.running = nil
        save()
    }

    /// Unmounts and deletes the snapshot this or an interrupted earlier run created.
    private func removeLeftovers() {
        LocalSnapshot.unmount(Paths.mount)
        if let date = state.localSnapshot {
            LocalSnapshot.delete(date)
            state.localSnapshot = nil
            save()
        }
    }

    private func finish(_ outcome: Outcome, reason: String?, step: String?, frozen: Bool, output: ClientOutput,
                        check: (checked: Int, mismatches: [String])? = nil) -> Exit {
        // A run that fails its check still wrote a snapshot; the record says which.
        let record = RunRecord(start: start, end: Date(), trigger: trigger, outcome: outcome, reason: reason, step: step,
                               snapshot: outcome == .success || step == "verify" ? output.snapshot : nil, frozen: frozen,
                               result: output.result, checkedFiles: check?.checked,
                               mismatches: check.flatMap { $0.mismatches.isEmpty ? nil : $0.mismatches },
                               changes: changes, log: logURL?.path)
        log("run \(outcome.rawValue)\(reason.map { ": " + $0 } ?? "")")
        // Keep `paused` as the app last set it.
        let paused = State.load().paused
        state.paused = paused
        state.finish(record)
        save()
        print("\(outcome.rawValue)\(reason.map { ": " + $0 } ?? "")\(record.snapshot.map { " " + $0 } ?? "")")
        try? logHandle?.close()
        Runner.removeOldLogs()
        return outcome == .failed ? .failed : .done
    }

    // MARK: - Log and state

    private func save() {
        do { try state.save() } catch { log("cannot write the state file: \(error)") }
    }

    private func openLog() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        let url = Paths.logs.appendingPathComponent("\(formatter.string(from: start)).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: url)
        logURL = url
    }

    private func log(_ line: String) {
        logHandle?.write(Data((line + "\n").utf8))
    }

    /// Logs are kept for 30 days.
    static func removeOldLogs(in folder: URL = Paths.logs, now: Date = Date()) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               now.timeIntervalSince(modified) > 30 * 86400 {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

enum Reachability {
    /// True when a TCP connection to `host:port` opens within `timeout` seconds.
    static func canConnect(host: String, port: Int, timeout: Int) -> Bool {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let first = list else { return false }
        defer { freeaddrinfo(list) }
        var entry: UnsafeMutablePointer<addrinfo>? = first
        while let info = entry {
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if fd >= 0 {
                defer { close(fd) }
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                let result = connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
                if result == 0 { return true }
                if errno == EINPROGRESS {
                    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    if poll(&descriptor, 1, Int32(timeout * 1000)) == 1 {
                        var failure: Int32 = 0
                        var length = socklen_t(MemoryLayout<Int32>.size)
                        getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &length)
                        if failure == 0 { return true }
                    }
                }
            }
            entry = info.pointee.ai_next
        }
        return false
    }
}

enum Power {
    /// Charge and power source from `pmset -g batt`; nil on a Mac without a battery.
    static func battery() -> (percent: Int, onAC: Bool)? {
        parse(tool("/usr/bin/pmset", ["-g", "batt"]).output)
    }

    static func parse(_ text: String) -> (percent: Int, onAC: Bool)? {
        guard let percentSign = text.firstIndex(of: "%") else { return nil }
        let digits = text[..<percentSign].reversed().prefix(while: \.isNumber).reversed()
        guard let percent = Int(String(digits)) else { return nil }
        return (percent, text.contains("'AC Power'"))
    }
}
