import AppKit
import os
import PBSMackupKit
import ServiceManagement
import SwiftUI
import UserNotifications

@main
enum Main {
    static func main() {
        #if DEBUG
        if let at = CommandLine.arguments.firstIndex(of: "--render") {
            Render.run(Array(CommandLine.arguments[(at + 1)...]))
        }
        #endif
        PBSMackupApp.main()
    }
}

struct PBSMackupApp: App {
    @StateObject private var model = StatusModel()

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(model: model)
        } label: {
            MenuBarLabel(symbol: model.symbol)
        }
        .menuBarExtraStyle(.window)
        // The panel grows with its content and would not shrink again: after a backup it kept the
        // height of the running state and showed the shorter menu in the middle of it.
        .windowResizability(.contentSize)

        Window(TimelineView.title, id: "timeline") {
            TimelineView()
        }

        Window("Backup Settings", id: "settings") {
            SettingsView()
        }
        .windowResizability(.contentMinSize)
    }
}

private struct MenuBarLabel: View {
    let symbol: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        #if DEBUG
        Image(systemName: symbol).onAppear { Shot.take(openWindow) }
        #else
        Image(systemName: symbol)
        #endif
    }
}

/// Reads the state file when it changes and offers the few actions the menu has.
final class StatusModel: ObservableObject {
    enum Status { case notSetUp, idle, running, waiting, paused, failing }

    @Published var state = State.load()
    /// Whether the run the state file names is still going, as of the last `reload`.
    @Published var live = false
    @Published var paused = Pause.isOn
    @Published var configured = FileManager.default.fileExists(atPath: Paths.config.path)
    /// How often a backup is made, in minutes: read again when the configuration was written.
    @Published var interval = 60
    private var configWritten: Date?
    @Published var agent = ""
    @Published var fullDiskAccess = FullDiskAccess.granted
    private var watcher: FolderWatcher?
    private var timer: Timer?

    init() {
        // Files opened from a backup to look at and backups opened in Finder that a previous run
        // of the app left behind, e.g. after a crash; and on quitting, the ones of this run.
        Paths.emptyPreview()
        DispatchQueue.global().async { Client.unmount() }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            Client.unmount()
            Paths.emptyPreview()
        }
        #if DEBUG
        if Shot.request == nil { registerJobs() }
        #else
        registerJobs()
        // The token and the key of a version before 0.2 move to where this version keeps them;
        // macOS asks for the login password for each. Nothing happens when there are none.
        Task { [weak self] in
            _ = try? await RunTool.call(["migrate"])
            await MainActor.run { self?.reload() }
        }
        #endif
        // The state file, the configuration and the pause file are all written into the support
        // folder, so a change there says when to read them again. The timer is for what no such
        // change announces: Full Disk Access switched on or off, three days gone by without a
        // backup, a run tool that died and left its record in the state file, and a
        // configuration that an editor rewrote in place.
        watcher = FolderWatcher(Paths.support) { [weak self] in self?.reload() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.reload() }
        timer?.tolerance = 10
        reload()
    }

    func reload() {
        let fresh = State.load()
        if fresh != state { state = fresh }
        let going = fresh.running?.isLive == true
        if going != live { live = going }
        let pause = Pause.isOn
        if pause != paused { paused = pause }
        let hasConfig = FileManager.default.fileExists(atPath: Paths.config.path)
        if hasConfig != configured { configured = hasConfig }
        // The interval is read when the configuration was written, not on every redraw of the menu.
        let file = Paths.config.resolvingSymlinksInPath().path
        let written = (try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date
        if written != configWritten {
            configWritten = written
            let minutes = (try? Config.load())?.interval ?? 60
            if minutes != interval { interval = minutes }
        }
        let access = FullDiskAccess.granted
        if access != fullDiskAccess { fullDiskAccess = access }
        notify()
    }

    /// Posts a system notification when backups keep failing or none has succeeded for three
    /// days. What was already said is kept in the app's preferences, so it is said once.
    private func notify() {
        let defaults = UserDefaults.standard
        var notices = defaults.data(forKey: "notices").flatMap { try? JSONDecoder().decode(Notices.self, from: $0) } ?? Notices()
        guard let notice = notices.check(state) else { return }
        defaults.set(try? JSONEncoder().encode(notices), forKey: "notices")
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    var status: Status {
        if !configured { return .notSetUp }
        if live { return .running }
        if state.last?.outcome == .failed { return .failing }
        if paused { return .paused }
        if state.last?.outcome == .skipped { return .waiting }
        return .idle
    }

    var symbol: String {
        switch status {
        case .notSetUp: "externaldrive.badge.questionmark"
        case .idle: "externaldrive.badge.timemachine"
        case .running: "arrow.triangle.2.circlepath"
        case .waiting: "externaldrive.badge.minus"
        case .paused: "pause.circle"
        case .failing: "externaldrive.badge.exclamationmark"
        }
    }

    /// When the next backup is due, by the rule the run tool goes by. launchd looks every five
    /// minutes, so it starts within five minutes of that.
    var nextRun: Date { max(Date(), state.nextRun(intervalMinutes: interval)) }

    // MARK: Actions

    /// The jobs that start the run tool live in the app bundle and are registered with launchd
    /// from here: one for the scheduled backups, one for a backup the owner asks for, and the
    /// helper the app talks to (`Identity.jobs`).
    func registerJobs() {
        // launchd finds the run tool through the app that registered the jobs, and starts only
        // the run tool it found then. After the app moved (from the build folder to
        // /Applications, say) or was replaced by another version or another build of itself,
        // the jobs are registered again from what is there now.
        let plists = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents")
        let built = Bundle.main.executableURL.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }
        var registered = Bundle.main.bundlePath + "\n" + "\(built?.timeIntervalSince1970 ?? 0)"
        for job in Identity.jobs {
            registered += "\n" + ((try? String(contentsOf: plists.appendingPathComponent("\(job).plist"), encoding: .utf8)) ?? "")
        }
        let defaults = UserDefaults.standard
        let changed = defaults.string(forKey: "registeredJob") != registered
        defaults.set(registered, forKey: "registeredJob")
        // The job of a version before 0.2, which launchd no longer starts; see `Identity.legacyLabel`.
        // Its description is still in the bundle for this alone.
        let old = SMAppService.agent(plistName: "\(Identity.legacyLabel).plist")
        if old.status == .enabled || old.status == .requiresApproval {
            let log = Logger(subsystem: Identity.bundleID, category: "jobs")
            do { try old.unregister(); log.notice("the job of an earlier version is unregistered") }
            catch { log.notice("the job of an earlier version: \(error.localizedDescription, privacy: .public)") }
        }
        for job in Identity.jobs {
            let service = SMAppService.agent(plistName: "\(job).plist")
            if service.status == .enabled, changed { try? service.unregister() }
            if changed || service.status != .enabled {
                // An error only counts when the job is not there afterwards.
                do { try service.register() } catch {
                    if service.status != .enabled { agent = "The backup job could not be registered: \(error.localizedDescription)" }
                }
            }
            if service.status == .requiresApproval { agent = "Allow PBS Mackup under Login Items in System Settings." }
        }
    }

    /// Starts the job for a backup by hand. It is none of launchd's background jobs, so the
    /// backup runs as fast as the Mac allows.
    func backUpNow() {
        tool("/bin/launchctl", ["kickstart", "gui/\(getuid())/\(Identity.manualLabel)"])
    }

    /// Only a run that is still going is signalled: the process id of one that ended without
    /// clearing its record may be another program's by now.
    func cancel() {
        if let running = state.running, running.isLive { kill(running.pid, SIGTERM) }
    }

    /// The pause is a file of its own, see `Pause`; the state file is the run tool's to write.
    func togglePause() {
        try? Pause.set(!Pause.isOn)
        reload()
    }

    func openLog() {
        if let log = state.last?.log { NSWorkspace.shared.open(URL(fileURLWithPath: log)) }
        else { NSWorkspace.shared.open(Paths.logs) }
    }

    static func openFullDiskAccess() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
}

struct StatusMenu: View {
    @ObservedObject var model: StatusModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(headline).font(.title3.bold())
                ForEach(details, id: \.text) { line in
                    Text(line.text).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(line.oneLine ? 1 : nil).truncationMode(.middle).fixedSize(horizontal: false, vertical: true)
                }
                if model.status == .running {
                    // A bar that fills when an earlier backup tells how much there is; moving stripes on a first one.
                    if let progress = model.state.running?.progress, let done = progress.bytesProcessed,
                       let expected = progress.expectedBytes, expected > 0 {
                        ProgressView(value: min(Double(done), Double(expected)), total: Double(expected)).padding(.top, 4)
                    } else {
                        ProgressView().progressViewStyle(.linear).padding(.top, 4)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
            Divider().padding(.horizontal, 16)
            VStack(spacing: 0) {
                if !model.agent.isEmpty { MenuNote(text: model.agent) }
                if !model.fullDiskAccess {
                    MenuNote(text: "Full Disk Access is off, so backups read the folders as they are, not a frozen snapshot of them.")
                    MenuRow(title: "Open Full Disk Access Settings", symbol: "lock.open", opens: true) { StatusModel.openFullDiskAccess() }
                }
                if model.status == .running {
                    MenuRow(title: "Cancel Backup", symbol: "xmark", trailing: started) { model.cancel() }
                } else {
                    MenuRow(title: "Back Up Now", symbol: "arrow.clockwise", trailing: nextBackup.map { "Next at \($0)" } ?? "") { model.backUpNow() }
                        .disabled(model.status == .notSetUp)
                }
                if model.paused {
                    MenuRow(title: "Resume Automatic Backups", symbol: "play.fill", trailing: "Paused") { model.togglePause() }
                } else {
                    MenuRow(title: "Pause Automatic Backups", symbol: "pause.fill") { model.togglePause() }
                }
                MenuRow(title: "Browse Backups…", symbol: "clock.arrow.circlepath", opens: true) {
                    openWindow(id: "timeline")
                    NSApp.activate(ignoringOtherApps: true)
                }.disabled(model.status == .notSetUp)
                MenuRow(title: model.status == .notSetUp ? "Set Up…" : "Settings…", symbol: "gearshape", opens: true) {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
                MenuRow(title: "Open Log", symbol: "doc.text", opens: true) { model.openLog() }
                MenuRow(title: "Quit", symbol: "power") { NSApp.terminate(nil) }
            }
            .padding(6)
        }
        .frame(width: 310)
        // What the timer looks at once a minute is looked at when the menu opens, too.
        .onAppear { model.reload() }
    }

    private var headline: String {
        switch model.status {
        case .notSetUp: "Not set up"
        case .idle: "Backups are up to date"
        case .running: "Backing up"
        case .waiting: "Waiting"
        case .paused: "Automatic backups are paused"
        case .failing: "Last backup failed"
        }
    }

    /// The grey lines under the headline. They wrap, all but the name of the file being read:
    /// that changes every second, and the panel would change its height with it.
    private var details: [(text: String, oneLine: Bool)] {
        var lines: [String] = []
        var file: Int?
        let state = model.state
        switch model.status {
        case .notSetUp:
            lines.append("No configuration at \(Paths.config.path).")
        case .running:
            if let progress = state.running?.progress {
                if let processed = progress.processed, let uploaded = progress.uploaded {
                    lines.append("\(processed) processed, \(uploaded) uploaded" + (progress.elapsed.map { " in \($0)" } ?? ""))
                    if let speed = progress.speed { lines.append("Uploading at \(speed)") }
                    if let path = progress.path, !path.isEmpty {
                        file = lines.count
                        lines.append((path as NSString).lastPathComponent)
                    }
                } else {
                    lines.append(progress.step.rawValue.prefix(1).uppercased() + progress.step.rawValue.dropFirst() + "…")
                }
            }
        case .waiting, .failing:
            if let reason = state.last?.reason { lines.append(reason) }
        case .idle, .paused:
            break
        }
        if let unreadable = state.last?.result.warnings?.count, unreadable > 0, model.status != .running {
            lines.append("\(unreadable) item\(unreadable == 1 ? "" : "s") could not be read and \(unreadable == 1 ? "was" : "were") left out. The log names \(unreadable == 1 ? "it" : "them").")
        }
        if let success = state.lastSuccess {
            lines.append("Last backup: \(success.end.formatted(date: .abbreviated, time: .shortened))" + summary(success))
        } else if model.status != .notSetUp {
            lines.append("No backup yet.")
        }
        if let nextBackup { lines.append("Next backup: \(nextBackup)") }
        return lines.enumerated().map { ($1, $0 == file) }
    }

    /// The time of the next scheduled run, when there is one to announce.
    private var nextBackup: String? {
        guard model.status != .running && model.status != .notSetUp && !model.paused else { return nil }
        let next = model.nextRun
        return next.timeIntervalSinceNow < 60 ? "within five minutes" : "about \(next.formatted(date: .omitted, time: .shortened))"
    }

    private var started: String {
        model.state.running.map { "Started \($0.start.formatted(date: .omitted, time: .shortened))" } ?? ""
    }

    private func summary(_ record: RunRecord) -> String {
        guard let data = record.result.archives.first(where: { $0.name.hasSuffix(".ppxar") }) ?? record.result.archives.first else { return "" }
        let checked = record.checkedFiles.map { $0 > 0 ? ", \($0) files checked" : "" } ?? ""
        return " (\(data.uploaded) of \(data.total) uploaded\(checked))"
    }
}

/// The round grey badge at the start of every row and note.
private struct MenuBadge: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .frame(width: 26, height: 26)
            .background(Color.primary.opacity(0.1), in: Circle())
    }
}

/// One action in the popover: badge, title, grey text at the right, and a chevron if it opens something.
private struct MenuRow: View {
    let title: String
    let symbol: String
    var trailing = ""
    var opens = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @SwiftUI.State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                MenuBadge(symbol: symbol)
                Text(title).lineLimit(1)
                Spacer(minLength: 8)
                Text(trailing).foregroundStyle(.secondary).lineLimit(1)
                if opens { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(Color.primary.opacity(hovered && enabled ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovered = $0 }
    }
}

/// A warning between the rows: not clickable, and the text wraps.
private struct MenuNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            MenuBadge(symbol: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            // Puts the first line level with the middle of the badge.
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true).padding(.top, 5)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
    }
}
