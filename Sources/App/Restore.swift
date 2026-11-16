import AppKit
import PBSMackupKit
import ServiceManagement
import SwiftUI

/// Restoring this Mac from a backup: the home folder of whoever is logged in comes back whole,
/// from a snapshot they pick, and takes the place of the one they have once they log out. Root
/// does it, as the restore daemon (`RestoreService`), which this window registers for the time
/// of the restore and takes away after. An administrator allows it with their password or
/// Touch ID. The token, the key and its passphrase go to the daemon in its messages and are
/// kept nowhere else; after the swap the app takes them back from the daemon and has the run
/// tool store them (`storeSecretsAgain`). The home folder from before, which is set aside, is
/// deleted here at Finish, as its owner: root deletes nothing in a folder that its owner can reach.
@MainActor
final class RestoreModel: ObservableObject {
    static let title = "Restore from a Backup"
    static let daemon = SMAppService.daemon(plistName: "\(Identity.restoreLabel).plist")

    @Published var repository = ""
    @Published var namespace = ""
    @Published var token = ""
    @Published var keyName: String?
    @Published var keyLocked = false
    @Published var passphrase = ""
    @Published var choices: RestoreChoices?
    @Published var chosen = ""
    @Published var state: RestoreState?
    @Published var helper = SMAppService.Status.notRegistered
    @Published var fullDiskAccess = FullDiskAccess.granted
    @Published var busy = false
    @Published var message = ""
    @Published var confirming = false
    /// A certificate the client does not accept by itself, waiting for the owner's yes.
    @Published var unconfirmed: ServerCertificate.Info?
    /// What Finish could not delete of the home folder set aside, waiting for the owner to
    /// say whether to finish all the same.
    @Published var leftBehind: Leftovers?
    private var confirmedFingerprint: String?
    private var key: Data?
    private var authorization: RestoreAuthorization?
    /// While Finish runs. The daemon takes its right out of the authorization database then,
    /// and a question after that would have it put the right back.
    private var finishing = false

    init() {
        if let config = try? Config.load() {
            repository = config.repository
            namespace = config.namespace
            confirmedFingerprint = config.fingerprint
        }
    }

    var canSearch: Bool { !busy && !repository.isEmpty && !token.isEmpty }
    var canRestore: Bool {
        !busy && choices != nil && !chosen.isEmpty && key != nil && (!keyLocked || !passphrase.isEmpty)
            && helper == .enabled && fullDiskAccess
    }
    /// Whether a restore is under way or waits for its last step; the form is not shown then.
    var underWay: Bool { state != nil }

    /// What the daemon and macOS say now; on opening and on coming back from System Settings.
    func refresh() async {
        helper = RestoreModel.daemon.status
        fullDiskAccess = FullDiskAccess.granted
        guard helper == .enabled else { state = nil; return }
        guard !finishing else { return }
        state = try? await RestoreDaemon.status()
    }

    /// Asks the restore daemon's state once a second while the restore runs or waits.
    func watch() async {
        while !Task.isCancelled {
            if !finishing, let phase = state?.phase, phase == .restoring || phase == .waitingForLogout {
                state = try? await RestoreDaemon.status()
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Registers the restore daemon. macOS asks the owner to allow it under Login Items first,
    /// so that page is opened; `refresh` sees the answer when the owner comes back.
    func allowHelper() {
        do { try RestoreModel.daemon.register() } catch {
            if RestoreModel.daemon.status != .requiresApproval { message = "The restore helper could not be registered: \(error.localizedDescription)" }
        }
        helper = RestoreModel.daemon.status
        if helper == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func chooseKey() {
        let panel = NSOpenPanel()
        panel.message = "Choose the recovery copy of your encryption key."
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        key = data
        keyName = url.lastPathComponent
        keyLocked = KeyStore.isLocked(data)
        passphrase = ""
    }

    private var request: RestoreRequest {
        RestoreRequest(repository: repository.trimmingCharacters(in: .whitespaces), namespace: namespace.trimmingCharacters(in: .whitespaces),
                       fingerprint: confirmedFingerprint, token: token.trimmingCharacters(in: .whitespacesAndNewlines), key: key ?? Data(),
                       passphrase: keyLocked ? passphrase : nil)
    }

    /// Checks the certificate, has an administrator allow the restore, and asks the server for the
    /// snapshots that hold this user's home folder.
    func findBackups() async {
        message = ""
        guard let server = Config(repository: repository, namespace: "", backupID: "", sources: []).server else {
            message = "The repository should look like user@realm!token@host:datastore."
            return
        }
        guard helper == .enabled else { message = "Allow the restore helper first."; return }
        await work {
            guard let certificate = await ServerCertificate.fetch(host: server.host, port: server.port) else {
                throw Failure(description: "The server \(server.host) is not reachable.")
            }
            if !certificate.trusted && certificate.fingerprint != confirmedFingerprint {
                unconfirmed = certificate      // the alert asks, and the owner searches again
                return
            }
            if certificate.trusted { confirmedFingerprint = nil }
            let request = request
            let choices = try await authorized { try await RestoreDaemon.snapshots(request, authorization: $0) }
            guard !choices.snapshots.isEmpty else {
                throw Failure(description: "No backup on this server holds a home folder named \(choices.archive).")
            }
            self.choices = choices
            chosen = choices.snapshots[0].name
        }
    }

    func trustCertificate() {
        confirmedFingerprint = unconfirmed?.fingerprint
        unconfirmed = nil
        Task { await findBackups() }
    }

    func restore() async {
        message = ""
        await work {
            var request = request
            request.snapshot = chosen
            try await authorized { try await RestoreDaemon.start(request, authorization: $0) }
            token = ""
            passphrase = ""
            key = nil
            state = try await RestoreDaemon.status()
        }
    }

    /// Asks macOS to log the owner out, as the Log Out item of the Apple menu does: open
    /// documents are offered for saving first. The restore daemon does the rest.
    func logOut() {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.loginwindow")
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAELogOut),
                                           targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        do { try event.sendEvent(options: [.noReply], timeout: 10) } catch {
            message = "Log out from the Apple menu: \(error.localizedDescription)"
        }
    }

    /// Ends the restore: deletes the folder set aside after a swap, has the daemon remove what
    /// was restored after a failure, and takes the restore daemon away again. What is in the
    /// folder set aside is deleted here, by the app as its owner, and the daemon only removes
    /// the emptied folder from /Users. What the owner cannot delete is shown to them and not
    /// handed to root; `leaving` finishes all the same and leaves it where it is.
    func finish(leaving: Bool = false) async {
        message = ""
        leftBehind = nil
        finishing = true
        defer { finishing = false }
        await work {
            var left = Leftovers()
            if let state, state.phase == .done, state.uid == getuid() {
                left = await Task.detached { HomeRestore.emptyAside(of: state) }.value
                guard left.isEmpty || leaving else { leftBehind = left; return }
            }
            let aside = state?.aside ?? ""
            try await authorized { try await RestoreDaemon.finish(authorization: $0) }
            authorization = nil
            try? await RestoreModel.daemon.unregister()
            state = nil
            choices = nil
            helper = RestoreModel.daemon.status
            if !left.isEmpty { message = "What could not be deleted is still in \(aside)." }
        }
    }

    /// What became of the token and the key after the swap, for the window to say; nil before
    /// `storeSecretsAgain` has run. A failure says what to do instead.
    static var secretsStored: Result<Void, Failure>?

    /// After the login that follows the swap: has the run tool store again the token and the
    /// key the restore was started with. They were in the Keychain of the home folder that was
    /// set aside, so the restored one has neither; the daemon kept them in its memory. Done
    /// before anything else asks the run tool for the backups.
    static func storeSecretsAgain() async {
        do {
            let secrets = try await RestoreDaemon.secrets()
            let stored = try await RunTool.decode(SettingsModel.SetupStatus.self, ["setup-status"])
            for step in try secrets.storing(over: stored.key) { _ = try await RunTool.call(step.arguments, input: step.input) }
            secretsStored = .success(())
        } catch {
            secretsStored = .failure(Failure(description: "Enter the API token in Settings and import the recovery copy of your key: \(error)"))
        }
    }

    /// What the owner is told when Finish could not delete everything.
    static func explanation(of left: Leftovers, in aside: String) -> String {
        let named = left.paths.prefix(3).map { $0.hasPrefix(aside + "/") ? String($0.dropFirst(aside.count + 1)) : $0 }
        let items = left.count == 1 ? "1 item is" : "\(left.count.formatted()) items are"
        return "\(items) still in \(aside), such as \(named.joined(separator: ", ")). PBS Mackup deletes your old home folder "
            + "as you and not as root, so what you may not delete stays. Check that PBS Mackup has Full Disk Access and try again, "
            + "or finish and remove the folder yourself: an administrator can with sudo rm -rf in Terminal."
    }

    /// Sends a message with the administrator's yes. It holds for five minutes
    /// (`RestoreService.rightDefinition`); when the daemon finds a kept one expired, the
    /// administrator is asked once more.
    private func authorized<T>(_ send: (Data) async throws -> T) async throws -> T {
        if let kept = authorization {
            do { return try await send(kept.externalForm) } catch where "\(error)" == RestoreService.refused {
                authorization = nil
            }
        }
        // The daemon puts the right into the authorization database when it starts, with the
        // rule and the words macOS asks with. A question starts it.
        _ = try? await RestoreDaemon.status()
        let made = try await Task.detached { try RestoreAuthorization() }.value
        authorization = made
        return try await send(made.externalForm)
    }

    private func work(_ body: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do { try await body() } catch { message = "\(error)" }
    }
}

/// Messages to the restore daemon. macOS checks that it is this developer's run tool.
enum RestoreDaemon {
    static func status() async throws -> RestoreState? {
        let data: Data? = try await ask { daemon, done in daemon.status { done(.success($0)) } }
        return try data.map { try JSONDecoder.iso8601.decode(RestoreState.self, from: $0) }
    }

    static func snapshots(_ request: RestoreRequest, authorization: Data) async throws -> RestoreChoices {
        let encoded = try JSONEncoder().encode(request)
        let data: Data = try await ask { daemon, done in
            daemon.snapshots(encoded, authorization: authorization) { data, error in
                done(data.map { .success($0) } ?? .failure(Failure(description: error ?? "The restore helper gave no answer.")))
            }
        }
        return try JSONDecoder.iso8601.decode(RestoreChoices.self, from: data)
    }

    static func start(_ request: RestoreRequest, authorization: Data) async throws {
        let encoded = try JSONEncoder().encode(request)
        try await ask { daemon, done in
            daemon.start(encoded, authorization: authorization) { done($0.map { .failure(Failure(description: $0)) } ?? .success(())) }
        }
    }

    static func finish(authorization: Data) async throws {
        try await ask { daemon, done in
            daemon.finish(authorization: authorization) { done($0.map { .failure(Failure(description: $0)) } ?? .success(())) }
        }
    }

    static func secrets() async throws -> RestoreSecrets {
        let data: Data = try await ask { daemon, done in
            daemon.secrets { data, error in
                done(data.map { .success($0) } ?? .failure(Failure(description: error ?? "The restore helper gave no answer.")))
            }
        }
        return try JSONDecoder().decode(RestoreSecrets.self, from: data)
    }

    /// Resumes whoever waits, once: an answer and the end of the connection can both arrive.
    private final class Once<T>: @unchecked Sendable {
        private var waiting: CheckedContinuation<T, Error>?
        private let lock = NSLock()
        init(_ waiting: CheckedContinuation<T, Error>) { self.waiting = waiting }
        func give(_ result: Result<T, Error>) {
            lock.lock()
            let waiting = self.waiting
            self.waiting = nil
            lock.unlock()
            waiting?.resume(with: result)
        }
    }

    private static func ask<T>(_ body: @escaping (RestoreProtocol, @escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = Once(continuation)
            let connection = NSXPCConnection(machServiceName: Identity.restoreLabel, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: RestoreProtocol.self)
            guard HelperConnection.restrict(connection, to: Identity.toolIdentifier) else {
                return once.give(.failure(Failure(description: "This app no longer matches its own signature. Install it again.")))
            }
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.give(.failure(Failure(description: "The restore helper did not answer: \(error.localizedDescription)")))
                connection.invalidate()
            } as? RestoreProtocol
            guard let proxy else {
                connection.invalidate()
                return once.give(.failure(Failure(description: "The restore helper cannot be asked.")))
            }
            body(proxy) { result in
                once.give(result)
                connection.invalidate()
            }
        }
    }
}

struct RestoreView: View {
    @StateObject private var model = RestoreModel()
    /// A state to show instead of asking the restore helper; for `--render restore` only.
    var preview: RestoreState? = nil

    var body: some View {
        Group {
            if let state = preview ?? model.state { progress(state) } else { form }
        }
        .frame(width: 600, height: 640)
        .alert("This server's certificate needs your confirmation", isPresented: Binding(
            get: { model.unconfirmed != nil }, set: { if !$0 { model.unconfirmed = nil } })) {
            Button("Trust This Server") { model.trustCertificate() }
            Button("Cancel", role: .cancel) { model.unconfirmed = nil }
        } message: {
            Text("PBS Mackup cannot verify it with the certificate authorities that macOS ships with. Compare this fingerprint with the one on the server's dashboard:\n\n\(model.unconfirmed?.fingerprint ?? "")")
        }
        .alert("Some of your old home folder could not be deleted", isPresented: Binding(
            get: { model.leftBehind != nil }, set: { if !$0 { model.leftBehind = nil } })) {
            Button("Finish Anyway") { Task { await model.finish(leaving: true) } }
            Button("Cancel", role: .cancel) { model.leftBehind = nil }
        } message: {
            Text(RestoreModel.explanation(of: model.leftBehind ?? Leftovers(), in: model.state?.aside ?? ""))
        }
        .task { if preview == nil && !Render.active { await model.refresh() } }
        .task { if preview == nil && !Render.active { await model.watch() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }      // coming back from System Settings
        }
    }

    // MARK: - Setting up the restore

    private var form: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "externaldrive.badge.timemachine")
                        .font(.system(size: 34)).foregroundStyle(.tint).frame(width: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Restore \(NSUserName())'s home folder").font(.headline)
                        Text("Your files, settings and login keychain come back as they were in the backup. They take the place of this home folder when you log out. Then log in with the password from your old Mac. PBS Mackup then stores the token and key you enter here again.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                permission("Full Disk Access", done: model.fullDiskAccess, detail: "Lets the restore put a home folder in place.") {
                    Button("Open Settings…") { StatusModel.openFullDiskAccess() }
                }
                permission("Restore helper", done: model.helper == .enabled,
                           detail: model.helper == .requiresApproval ? "Turn on PBS Mackup under Login Items." : "Restores as root while you stay logged in. Removed when you finish.") {
                    Button(model.helper == .requiresApproval ? "Open Settings…" : "Allow…") { model.allowHelper() }
                }
            } header: {
                Text("Permissions")
            }

            Section("Backup server") {
                TextField("Repository", text: $model.repository, prompt: Text("user@realm!token@host:datastore"))
                TextField("Namespace", text: $model.namespace, prompt: Text("optional"))
                SecureField("API token secret", text: $model.token, prompt: Text("paste the secret"))
            }

            Section("Encryption key") {
                LabeledContent("Recovery copy") {
                    HStack(spacing: 8) {
                        if let name = model.keyName {
                            Label(name, systemImage: "key.fill").labelStyle(.titleAndIcon).foregroundStyle(.secondary)
                        }
                        Button(model.keyName == nil ? "Choose…" : "Change…") { model.chooseKey() }
                    }
                }
                if model.keyLocked { SecureField("Passphrase", text: $model.passphrase) }
            }

            if let choices = model.choices {
                Section("Snapshot") {
                    Picker("Restore from", selection: $model.chosen) {
                        ForEach(choices.snapshots) { snapshot in
                            Text(label(snapshot)).tag(snapshot.name)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .confirmationDialog("Restore your home folder from this backup?", isPresented: $model.confirming) {
            Button("Restore") { Task { await model.restore() } }
        } message: {
            Text("When you log out, the restored folder takes the place of your home folder, and what you saved in this account until then is set aside. iCloud Drive and other cloud storage are left out: they come back when you sign in.")
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if model.busy { ProgressView().controlSize(.small) }
            Text(model.message.isEmpty ? hint : model.message)
                .font(.callout).foregroundStyle(model.message.isEmpty ? Color.secondary : Color.red)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            if model.choices == nil {
                Button("Find Backups") { Task { await model.findBackups() } }
                    .keyboardShortcut(.defaultAction).disabled(!model.canSearch || model.helper != .enabled)
            } else {
                Button("Find Again") { Task { await model.findBackups() } }.disabled(!model.canSearch)
                Button("Restore…") { model.confirming = true }
                    .keyboardShortcut(.defaultAction).disabled(!model.canRestore)
            }
        }
        .padding(12)
        .background(.bar)
    }

    /// What is still missing, in the order the window asks for it.
    private var hint: String {
        if !model.fullDiskAccess { return "Turn on Full Disk Access." }
        if model.helper != .enabled { return "Allow the restore helper." }
        if model.repository.isEmpty || model.token.isEmpty { return "Enter the backup server and its token." }
        if model.keyName == nil { return "Choose the recovery copy of your key." }
        if model.choices == nil { return "An administrator allows the restore when you look for backups." }
        return "The newest snapshot is chosen."
    }

    private func permission<Action: View>(_ title: String, done: Bool, detail: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(done ? Color.green : Color.orange).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if done { Text("On").foregroundStyle(.secondary) } else { action() }
        }
    }

    private func label(_ snapshot: Client.Snapshot) -> String {
        let mac = snapshot.name.split(separator: "/").dropFirst().first.map(String.init) ?? snapshot.name
        let size = snapshot.size.map { " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
        return "\(snapshot.time.formatted(date: .abbreviated, time: .shortened)) · \(mac)\(size)"
    }

    // MARK: - While and after restoring

    private func progress(_ state: RestoreState) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: symbol(state.phase))
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(state.phase == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                    .symbolEffect(.pulse, isActive: state.phase == .restoring)
                Text(title(state.phase)).font(.title2.weight(.semibold))
                Text(explanation(state))
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 440)
                if state.phase == .restoring {
                    VStack(spacing: 6) {
                        ProgressView(value: state.progress ?? 0)
                        Text((state.progress ?? 0).formatted(.percent.precision(.fractionLength(0))))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 360)
                }
                if !notes(state).isEmpty && state.phase != .restoring {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(notes(state), id: \.self) { note in
                            Label(note, systemImage: "checkmark")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: 440, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                }
                if state.phase == .done, case .failure(let failure) = RestoreModel.secretsStored {
                    Text(failure.description).font(.callout).foregroundStyle(.red)
                        .multilineTextAlignment(.center).frame(maxWidth: 440)
                }
                if !model.message.isEmpty {
                    Text(model.message).font(.callout).foregroundStyle(.red)
                        .multilineTextAlignment(.center).frame(maxWidth: 440)
                }
                Spacer()
            }
            .padding(.horizontal, 32)
            HStack {
                if state.phase == .waitingForLogout {
                    Button("Cancel Restore", role: .destructive) { Task { await model.finish() } }
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                switch state.phase {
                case .restoring: EmptyView()
                case .waitingForLogout: Button("Log Out…") { model.logOut() }.keyboardShortcut(.defaultAction)
                case .done: Button("Finish") { Task { await model.finish() } }.keyboardShortcut(.defaultAction)
                case .failed: Button("Start Over") { Task { await model.finish() } }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
            .background(.bar)
        }
    }

    /// What the daemon noted, and once the folder is in place, that the token and the key are stored again.
    private func notes(_ state: RestoreState) -> [String] {
        guard state.phase == .done, case .success = RestoreModel.secretsStored else { return state.notes }
        return state.notes + ["Your API token and encryption key are stored on this Mac again."]
    }

    private func symbol(_ phase: RestoreState.Phase) -> String {
        switch phase {
        case .restoring: "arrow.down.circle"
        case .waitingForLogout: "rectangle.portrait.and.arrow.right"
        case .done: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private func title(_ phase: RestoreState.Phase) -> String {
        switch phase {
        case .restoring: "Restoring your home folder"
        case .waitingForLogout: "Log out to finish"
        case .done: "Your home folder is back"
        case .failed: "The restore did not finish"
        }
    }

    private func explanation(_ state: RestoreState) -> String {
        let stamp = state.snapshot.split(separator: "/").last.map(String.init) ?? state.snapshot
        let when = ISO8601DateFormatter().date(from: stamp)?.formatted(date: .long, time: .shortened) ?? stamp
        switch state.phase {
        case .restoring:
            return "From the backup of \(when). You can keep using the Mac; what you save in this account until you log out is set aside."
        case .waitingForLogout:
            return "Everything is restored. When you log out, it takes the place of the home folder you are using now. Then log in with the password from your old Mac."
        case .done:
            return "The home folder from before the restore is set aside as \(state.aside). Finish deletes it and removes the restore helper."
        case .failed:
            return state.message ?? "Something went wrong."
        }
    }
}
