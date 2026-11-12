import AppKit
import PBSMackupKit
import SwiftUI

/// Setup and settings: where to back up to, what to back up, the encryption key and its
/// recovery copy, and Full Disk Access. Nothing is saved before the server accepted the values.
@MainActor
final class SettingsModel: ObservableObject {
    struct SetupStatus: Decodable {
        let configured: Bool, token: Bool
        let key: KeyStore.Status
    }

    @Published var repository = ""
    @Published var namespace = ""
    @Published var backupID = Host.current().localizedName?.replacingOccurrences(of: " ", with: "-").lowercased() ?? "mac"
    /// Empty means: keep the token that is stored.
    @Published var token = ""
    @Published var sources: [String] = []
    /// What to leave out, as the client takes it; see `LeaveOut`.
    @Published var rules: [String] = [] { didSet { recount() } }
    @Published var intervalMinutes = 60
    /// The last measurement of each backed-up folder, and which are being measured now.
    @Published var measured: [String: FolderSizes] = [:] { didSet { recount() } }
    @Published var measuring: Set<String> = []
    /// What the rules make of the measurements; kept because the list is redrawn often.
    @Published private(set) var rows: [String: [LeaveOut.Item]] = [:]
    @Published private(set) var tally = LeaveOut.Tally()
    @Published private(set) var suggestions: [Suggestions.Suggestion] = []
    @Published var expanded: Set<String> = []
    @Published var tab = Tab.backup
    enum Tab { case backup, server, key }
    @Published var status: SetupStatus?
    @Published var fullDiskAccess = FullDiskAccess.granted
    @Published var busy = false
    @Published var message = ""
    /// What the server was last asked about and accepted; Done needs it to be the current values.
    @Published var accepted: Connection?
    struct Connection: Equatable { var repository, namespace, backupID: String, fingerprint: String? }
    var connection: Connection {
        let config = config
        return Connection(repository: config.repository, namespace: config.namespace, backupID: config.backupID,
                          fingerprint: config.fingerprint)
    }
    /// A certificate that is not publicly trusted, waiting for the owner's yes.
    @Published var unconfirmed: ServerCertificate.Info?
    private var confirmedFingerprint: String?
    /// A key made in this window needs a recovery copy before setup can finish.
    @Published var keyIsNew = false
    @Published var recoveryExported = false
    @Published var recoveryConfirmed = false

    private var stored: Config?

    var config: Config {
        var config = stored ?? Config(repository: "", namespace: "", backupID: "", sources: [])
        config.repository = repository.trimmingCharacters(in: .whitespaces)
        config.namespace = namespace.trimmingCharacters(in: .whitespaces)
        config.backupID = backupID.trimmingCharacters(in: .whitespaces)
        config.sources = sources
        config.excludes = rules
        config.intervalMinutes = intervalMinutes == 60 ? nil : intervalMinutes
        config.fingerprint = confirmedFingerprint
        return config
    }

    var canFinish: Bool {
        accepted == connection && token.isEmpty && status?.key.present == true && !sources.isEmpty
            && (!keyIsNew || (recoveryExported && recoveryConfirmed))
    }

    func load() async {
        if let config = try? Config.load() {
            stored = config
            repository = config.repository
            namespace = config.namespace
            backupID = config.backupID
            sources = config.sources
            rules = config.excludes
            intervalMinutes = config.interval
            confirmedFingerprint = config.fingerprint
        } else {
            // A first setup starts with the whole home folder; the list below is for thinning it out.
            sources = [NSHomeDirectory()]
        }
        if let override = ProcessInfo.processInfo.environment["PBS_MACKUP_RENDER_SOURCES"] { sources = override.components(separatedBy: ":") }
        expanded = Set(sources)
        for path in ProcessInfo.processInfo.environment["PBS_MACKUP_RENDER_EXPAND"]?.components(separatedBy: ":") ?? [] {
            expanded.insert(sources[0] + "\u{0}" + path)
        }
        switch CommandLine.arguments.last {
        case "server": tab = .server
        case "key": tab = .key
        default: break
        }
        await refreshStatus()
        // What was stored went through the server check when it was saved.
        if stored != nil, status?.token == true { accepted = connection }
        for source in sources {
            if let known = FolderSizes.load(for: source) { measured[source] = known }
            // Sizes drift; a day-old measurement is still good enough to open with.
            if measured[source].map({ $0.measured < Date().addingTimeInterval(-86400) }) ?? true { measure(source) }
        }
    }

    func refreshStatus() async {
        if Render.active { return }
        status = try? await RunTool.decode(SetupStatus.self, ["setup-status"])
        fullDiskAccess = FullDiskAccess.granted
    }

    private func recount() {
        var rows: [String: [LeaveOut.Item]] = [:]
        var tally = LeaveOut.Tally()
        var suggestions: [Suggestions.Suggestion] = []
        for (source, sizes) in measured where sources.contains(source) {
            rows[source] = LeaveOut.items(sizes, rules: rules)
            let one = LeaveOut.tally(sizes, rules: rules)
            tally.backedUp += one.backedUp; tally.byRules += one.byRules
            tally.automatic += one.automatic; tally.shared += one.shared
            for suggestion in Suggestions.find(in: sizes, rules: rules) where !suggestions.contains(where: { $0.rule == suggestion.rule }) {
                suggestions.append(suggestion)
            }
        }
        self.rows = rows
        self.tally = tally
        self.suggestions = suggestions.sorted { $0.bytes > $1.bytes }
    }

    /// Leaves an item out, or takes it back in when a rule of its own left it out.
    func toggle(_ item: LeaveOut.Item) {
        switch item.state {
        case .included, .partly:
            let rule = LeaveOut.rule(forPath: item.relative)
            // Rules for single items below it have nothing left to do.
            rules = rules.filter { LeaveOut.path(of: $0).map { !$0.hasPrefix(item.relative + "/") } ?? true } + [rule]
        case .leftOut(let rule, own: true):
            rules.removeAll { $0 == rule }
        default:
            break
        }
    }

    func add(rule: String) {
        let rule = rule.trimmingCharacters(in: .whitespaces)
        if !rule.isEmpty, !rules.contains(rule) { rules.append(rule) }
    }

    /// Leaves out items picked in an open panel; they have to be inside a backed-up folder.
    func leaveOutChosen() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        panel.prompt = "Leave Out"
        panel.directoryURL = sources.first.map { URL(fileURLWithPath: $0) }
        guard panel.runModal() == .OK else { return }
        message = ""
        for url in panel.urls {
            guard let source = sources.first(where: { url.path.hasPrefix($0 + "/") }) else {
                message = "\(url.lastPathComponent) is not inside a folder that is backed up."
                continue
            }
            add(rule: LeaveOut.rule(forPath: String(url.path.dropFirst(source.count + 1))))
        }
    }

    func remove(source: String) {
        sources.removeAll { $0 == source }
        measured[source] = nil
    }

    private func work(_ body: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do { try await body() } catch { message = "\(error)" }
    }

    /// Checks the certificate, then lets the server judge repository, namespace and token.
    func testConnection() async {
        accepted = nil
        message = ""
        let candidate = config
        guard let server = candidate.server else { message = "The repository should look like user@realm!token@host:datastore."; return }
        await work {
            guard let certificate = await ServerCertificate.fetch(host: server.host, port: server.port) else {
                throw Client.Failure(description: "The server \(server.host) is not reachable.")
            }
            if !certificate.trusted && certificate.fingerprint != confirmedFingerprint {
                unconfirmed = certificate      // the alert calls back with the answer
                return
            }
            if certificate.trusted { confirmedFingerprint = nil }
            let asked = connection
            try config.save()
            if !token.isEmpty {
                _ = try await RunTool.call(["set-token"], input: Data(token.utf8))
                token = ""
            }
            _ = try await RunTool.call(["check"])
            stored = config
            accepted = asked
            message = "The server accepted the connection."
            await refreshStatus()
        }
    }

    func confirmCertificate() async {
        confirmedFingerprint = unconfirmed?.fingerprint
        unconfirmed = nil
        await testConnection()
    }

    func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Back Up"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { add(source: url.path) }
    }

    func add(source: String) {
        guard !sources.contains(source) else { return }
        sources.append(source)
        expanded.insert(source)
        if let known = FolderSizes.load(for: source) { measured[source] = known }
        measure(source)
    }

    /// Measures a folder and what is in it. The run tool does it: with Full Disk Access it
    /// can read every folder, which the app itself cannot.
    func measure(_ source: String) {
        guard !measuring.contains(source), !Render.active else { return }
        measuring.insert(source)
        Task {
            do {
                _ = try await RunTool.call(["sizes", source])
                if sources.contains(source), let sizes = FolderSizes.load(for: source) { measured[source] = sizes }
            } catch { message = "\(error)" }
            measuring.remove(source)
        }
    }

    @Published var confirmingReplacement = false

    /// `replacing` an existing key: earlier backups then need the old key's recovery copy.
    func createKey(replacing: Bool = false) async {
        await work {
            _ = try await RunTool.call(["create-key"] + (replacing ? ["--replace"] : []))
            keyIsNew = true
            recoveryExported = false
            recoveryConfirmed = false
            await refreshStatus()
        }
    }

    func importKey() async {
        let panel = NSOpenPanel()
        panel.message = "Choose the recovery copy of your encryption key."
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        await work {
            _ = try await RunTool.call(["set-key"], input: data)
            keyIsNew = false
            await refreshStatus()
        }
    }

    func saveRecoveryFile() async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "pbs-backup-key-\(backupID).json"
        panel.message = "Keep this file somewhere other than this Mac, for example in your password manager."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await work {
            _ = try await RunTool.call(["export-key", url.path])
            recoveryExported = true
        }
    }

    func printPaperKey() async {
        await work {
            let text = try await RunTool.decode([String: String].self, ["paper-key"])["text"] ?? ""
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 720))
            view.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
            view.string = text
            if NSPrintOperation(view: view).run() { recoveryExported = true }
        }
    }

    func finish() -> Bool {
        do { try config.save(); return true } catch { message = "\(error)"; return false }
    }
}

struct SettingsView: View {
    @StateObject private var model = SettingsModel()
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        TabView(selection: $model.tab) {
            WhatToBackUpView(model: model)
                .tabItem { Text("What to Back Up") }.tag(SettingsModel.Tab.backup)
            serverTab
                .tabItem { Text("Server") }.tag(SettingsModel.Tab.server)
            keyTab
                .tabItem { Text("Encryption Key") }.tag(SettingsModel.Tab.key)
        }
        .padding(.top, 10)
        .frame(minWidth: 900, idealWidth: 940, minHeight: 620, idealHeight: 700)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(finishHint).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { if model.finish() { dismissWindow(id: "settings") } }
                    .keyboardShortcut(.defaultAction).disabled(!model.canFinish)
            }
            .padding(12)
            .background(.bar)
        }
        .alert("This server's certificate is not publicly trusted", isPresented: Binding(
            get: { model.unconfirmed != nil }, set: { if !$0 { model.unconfirmed = nil } })) {
            Button("Trust This Server") { Task { await model.confirmCertificate() } }
            Button("Cancel", role: .cancel) { model.unconfirmed = nil }
        } message: {
            Text("Compare this fingerprint with the one on the server's dashboard:\n\n\(model.unconfirmed?.fingerprint ?? "")")
        }
        .task { await model.load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshStatus() }      // coming back from System Settings
        }
    }

    private var serverTab: some View {
        Form {
            Section("Server") {
                TextField("Repository", text: $model.repository, prompt: Text("user@realm!token@host:datastore"))
                TextField("Namespace", text: $model.namespace)
                TextField("Name of this Mac's backups", text: $model.backupID)
                SecureField("API token secret", text: $model.token,
                            prompt: Text(model.status?.token == true ? "stored in the Keychain; type to replace" : "paste the secret"))
                HStack {
                    Button("Test Connection") { Task { await model.testConnection() } }
                        .disabled(model.busy || model.repository.isEmpty)
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.message).foregroundStyle(model.accepted == nil ? .red : .secondary)
                        .font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                LabeledContent("Full Disk Access", value: model.fullDiskAccess ? "On" : "Off")
                if !model.fullDiskAccess {
                    Button("Open Full Disk Access Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                }
            } header: {
                Text("Permission")
            } footer: {
                Text("A backup reads from a frozen snapshot of the disk, so files cannot change halfway through. macOS only lets an app mount that snapshot, and read Mail, Messages or Photos, with Full Disk Access. Without it the folders are read as they are.")
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }

    private var keyTab: some View {
        Form {
            Section {
                if let key = model.status?.key, key.present {
                    LabeledContent("Key", value: key.fingerprint.map { String($0.prefix(23)) } ?? "stored")
                    HStack {
                        Button("Save Recovery File…") { Task { await model.saveRecoveryFile() } }
                        Button("Print Paper Key…") { Task { await model.printPaperKey() } }
                        Spacer()
                        Button("Replace Key…", role: .destructive) { model.confirmingReplacement = true }
                    }
                    .confirmationDialog("Replace the encryption key?", isPresented: $model.confirmingReplacement) {
                        Button("Replace Key", role: .destructive) { Task { await model.createKey(replacing: true) } }
                    } message: {
                        Text("New backups will use a new key. Earlier backups can then only be read with the recovery copy of the current key, so save that first if you still want them.")
                    }
                    if model.keyIsNew {
                        Toggle("I stored the recovery copy somewhere other than this Mac", isOn: $model.recoveryConfirmed)
                            .disabled(!model.recoveryExported)
                    }
                } else {
                    HStack {
                        Button("Create New Key") { Task { await model.createKey() } }
                        Button("Import Existing Key…") { Task { await model.importKey() } }
                    }
                }
            } header: {
                Text("Encryption key")
            } footer: {
                Text("Backups are encrypted on this Mac. Without the key or its recovery copy nobody can read them, you included. To read earlier backups on a new Mac, import the recovery copy.")
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }

    private var finishHint: String {
        if model.sources.isEmpty { return "Add at least one folder to back up." }
        if model.status?.key.present != true { return "Create or import an encryption key, under Encryption Key." }
        if model.keyIsNew && !model.recoveryExported { return "Save or print the recovery copy of the new key, under Encryption Key." }
        if model.keyIsNew && !model.recoveryConfirmed { return "Confirm that the recovery copy is stored, under Encryption Key." }
        if !model.token.isEmpty || model.accepted != model.connection { return "Test the connection, under Server." }
        return ""
    }
}
