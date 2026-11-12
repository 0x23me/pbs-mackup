import AppKit
import PBSMackupKit
import ServiceManagement
import SwiftUI
import UserNotifications

@main
enum Main {
    static func main() {
        if let at = CommandLine.arguments.firstIndex(of: "--render") {
            Render.run(Array(CommandLine.arguments[(at + 1)...]))
        }
        PBSMackupApp.main()
    }
}

struct PBSMackupApp: App {
    @StateObject private var model = StatusModel()

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(model: model)
        } label: {
            Image(systemName: model.symbol)
        }
        .menuBarExtraStyle(.window)

        Window("Backups", id: "timeline") {
            TimelineView()
        }

        Window("Backup Settings", id: "settings") {
            SettingsView()
        }
        .windowResizability(.contentMinSize)
    }
}

/// Reads the state file once a second and offers the few actions the menu has.
final class StatusModel: ObservableObject {
    enum Status { case notSetUp, idle, running, waiting, paused, failing }

    @Published var state = State.load()
    @Published var configured = FileManager.default.fileExists(atPath: Paths.config.path)
    @Published var agent = ""
    @Published var fullDiskAccess = FullDiskAccess.granted
    private var timer: Timer?

    init() {
        // Files opened from a backup to look at are copies; a restored folder may carry an ACL
        // that forbids deleting it, so that goes first.
        tool("/bin/chmod", ["-R", "-N", Paths.preview.path])
        try? FileManager.default.removeItem(at: Paths.preview)
        // Backups a previous run of the app left open in Finder, e.g. after a crash; and on
        // quitting, the ones this run opened.
        DispatchQueue.global().async { Client.unmount() }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            Client.unmount()
        }
        registerAgent()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.reload() }
    }

    func reload() {
        let fresh = State.load()
        if fresh != state { state = fresh }
        let hasConfig = FileManager.default.fileExists(atPath: Paths.config.path)
        if hasConfig != configured { configured = hasConfig }
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
        if let running = state.running, kill(running.pid, 0) == 0 { return .running }
        if state.last?.outcome == .failed { return .failing }
        if state.paused { return .paused }
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

    /// When the next backup is due: one interval after the last run began. launchd looks
    /// every five minutes, so it starts within five minutes of that.
    var nextRun: Date {
        let interval = (try? Config.load())?.interval ?? 60
        guard let last = state.last?.start else { return Date() }
        return max(Date(), last.addingTimeInterval(Double(interval * 60)))
    }

    // MARK: Actions

    /// The job that starts the run tool lives in the app bundle and is registered with launchd from here.
    func registerAgent() {
        let service = SMAppService.agent(plistName: "\(agentLabel).plist")
        // launchd finds the run tool through the app that registered the job. After the app
        // moved (from the build folder to /Applications, say) the job is registered again from
        // where it is now.
        // The same goes for a new version of the app whose job is described differently.
        let defaults = UserDefaults.standard
        let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/\(agentLabel).plist")
        let registered = Bundle.main.bundlePath + "\n" + ((try? String(contentsOf: plist, encoding: .utf8)) ?? "")
        if service.status == .enabled, defaults.string(forKey: "registeredJob") != registered {
            try? service.unregister()
        }
        defaults.set(registered, forKey: "registeredJob")
        if service.status != .enabled {
            do { try service.register() } catch { agent = "The backup job could not be registered: \(error.localizedDescription)" }
        }
        if service.status == .requiresApproval { agent = "Allow PBS Mackup under Login Items in System Settings." }
    }

    func backUpNow() {
        try? Paths.createFolders()
        FileManager.default.createFile(atPath: Paths.manualRequest.path, contents: nil)
        tool("/bin/launchctl", ["kickstart", "gui/\(getuid())/\(agentLabel)"])
    }

    func cancel() {
        if let pid = state.running?.pid { kill(pid, SIGTERM) }
    }

    func togglePause() {
        var fresh = State.load()
        fresh.paused.toggle()
        try? fresh.save()
        reload()
    }

    func openLog() {
        if let log = state.last?.log { NSWorkspace.shared.open(URL(fileURLWithPath: log)) }
        else { NSWorkspace.shared.open(Paths.logs) }
    }

    func openFullDiskAccess() {
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
                ForEach(details, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
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
                    MenuRow(title: "Open Full Disk Access Settings", symbol: "lock.open", opens: true) { model.openFullDiskAccess() }
                }
                if model.status == .running {
                    MenuRow(title: "Cancel Backup", symbol: "xmark", trailing: started) { model.cancel() }
                } else {
                    MenuRow(title: "Back Up Now", symbol: "arrow.clockwise", trailing: nextBackup.map { "Next at \($0)" } ?? "") { model.backUpNow() }
                        .disabled(model.status == .notSetUp)
                }
                if model.state.paused {
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

    private var details: [String] {
        var lines: [String] = []
        let state = model.state
        switch model.status {
        case .notSetUp:
            lines.append("No configuration at \(Paths.config.path).")
        case .running:
            if let progress = state.running?.progress {
                if let processed = progress.processed, let uploaded = progress.uploaded {
                    lines.append("\(processed) processed, \(uploaded) uploaded" + (progress.elapsed.map { " in \($0)" } ?? ""))
                    if let speed = progress.speed { lines.append("Uploading at \(speed)") }
                    if let path = progress.path, !path.isEmpty { lines.append((path as NSString).lastPathComponent) }
                } else {
                    lines.append(progress.step.prefix(1).uppercased() + progress.step.dropFirst() + "…")
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
        return lines
    }

    /// The time of the next scheduled run, when there is one to announce.
    private var nextBackup: String? {
        guard model.status != .running && model.status != .notSetUp && !model.state.paused else { return nil }
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
    @State private var hovered = false

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
