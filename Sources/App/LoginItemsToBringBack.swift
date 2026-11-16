import AppKit
import PBSMackupKit
import SwiftUI

/// Which snapshot's login items the screen shows; the value its window is opened with.
struct LoginItemsRequest: Codable, Hashable {
    var snapshot: String
    var hasSettings: Bool
}

/// The login items a snapshot recorded, and what can be done with each on this Mac. While the
/// screen is visible it looks again every two seconds, so a row changes after an install or an add.
@MainActor
final class LoginItemsModel: ObservableObject {
    enum Recorded: Equatable {
        case loading
        /// The snapshot is from before login items were recorded.
        case none
        /// They couldn't be read when the backup was made, for this reason.
        case unavailable(String)
        case items([LoginItem])
        case failed(String)
    }

    @Published var recorded = Recorded.loading
    /// The "Open at Login" list now.
    @Published var current: [LoginItem] = []
    @Published var installed: [LoginItem: URL] = [:]
    @Published var permission: LoginItems.Permission?
    @Published var message = ""

    var items: [LoginItem] {
        if case .items(let items) = recorded { return items }
        return []
    }

    func restorable(_ item: LoginItem) -> LoginItems.Restorable {
        LoginItems.restorable(item, current: current, installed: installed[item])
    }

    var addable: [(LoginItem, URL)] {
        items.compactMap { item in
            if case .add(let url) = restorable(item) { return (item, url) }
            return nil
        }
    }

    func load(_ request: LoginItemsRequest) async {
        guard request.hasSettings else { recorded = .none; return }
        do {
            let manifest = try await RunTool.decode(SettingsManifest.self, ["settings", request.snapshot])
            let section = manifest.loginItems
            recorded = section.status == .ok ? .items(section.items) : .unavailable(section.reason ?? "No reason was recorded.")
        } catch {
            recorded = .failed(error.localizedDescription)
        }
    }

    func watch() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func refresh() async {
        let items = self.items
        let (permission, current, installed) = await Task.detached {
            let permission = LoginItems.permission(ask: false)
            let current = permission == .granted ? (try? LoginItems.read()) ?? [] : []
            var installed: [LoginItem: URL] = [:]
            for item in items { installed[item] = LoginItems.installed(item) }
            return (permission, current, installed)
        }.value
        self.permission = permission
        self.current = current
        self.installed = installed
    }

    func allow() async {
        permission = await Task.detached { LoginItems.permission(ask: true) }.value
        await refresh()
    }

    func add(_ items: [(LoginItem, URL)]) async {
        message = ""
        let failures = await Task.detached {
            items.compactMap { item, url -> String? in
                do { try LoginItems.add(url); return nil } catch { return "\(item.name): \(error)" }
            }
        }.value
        message = failures.joined(separator: "\n")
        await refresh()
    }
}

struct LoginItemsView: View {
    /// The window is the Mac Settings layer of a snapshot; login items are its first part.
    static let title = "Mac Settings"

    let request: LoginItemsRequest
    @StateObject private var model = LoginItemsModel()
    /// What to show instead of asking System Events and the run tool; for `--render login-items` only.
    var preview: LoginItemsModel? = nil

    private var shown: LoginItemsModel { preview ?? model }

    var body: some View {
        Form {
            Section {
                Text("Login Items to Bring Back").font(.headline)
                Text(shown.items.isEmpty ? "Backup from \(Self.date(request.snapshot))."
                     : "These apps opened at login when the backup from \(Self.date(request.snapshot)) was made.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 480)
        .task { if preview == nil && !Render.active { await model.load(request); await model.watch() } }
    }

    @ViewBuilder private var content: some View {
        switch shown.recorded {
        case .loading:
            Section { ProgressView().frame(maxWidth: .infinity) }
        case .none:
            Section { Text("This backup has no recorded login items. It was made before PBS Mackup recorded them.") }
        case .unavailable(let reason):
            Section { Text("Login items couldn't be recorded when this backup was made: \(reason)") }
        case .failed(let reason):
            Section { Text("The recorded login items couldn't be read: \(reason)").foregroundStyle(.red) }
        case .items(let items) where items.isEmpty:
            Section { Text("No apps opened at login on that Mac.") }
        case .items(let items):
            if shown.permission != .granted { permissionSection }
            Section {
                ForEach(items, id: \.self) { row($0) }
            } footer: {
                HStack {
                    Text(shown.message).foregroundStyle(.red).font(.callout)
                    Spacer()
                    Button("Add All") { Task { await model.add(model.addable) } }
                        .disabled(shown.addable.isEmpty || shown.permission != .granted)
                }
            }
        }
    }

    private var permissionSection: some View {
        Section {
            HStack {
                Text(shown.permission == .denied
                     ? "PBS Mackup isn't allowed to control System Events, which adds login items. Turn it on in System Settings."
                     : "To add login items, allow PBS Mackup to control System Events.")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if shown.permission == .denied {
                    Button("Open Automation Settings") { StatusModel.openAutomation() }
                } else {
                    Button("Allow…") { Task { await model.allow() } }
                }
            }
        }
    }

    private func row(_ item: LoginItem) -> some View {
        let state = shown.restorable(item)
        return HStack {
            Image(nsImage: icon(shown.installed[item]))
                .resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading) {
                Text(item.name)
                Text(item.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            switch state {
            case .done:
                Label("Added", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .add(let url):
                Button("Add") { Task { await model.add([(item, url)]) } }
                    .disabled(shown.permission != .granted)
            case .installFirst:
                Text("Install first").foregroundStyle(.secondary)
            }
        }
    }

    private func icon(_ installed: URL?) -> NSImage {
        installed.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .applicationBundle)
    }

    /// `host/my-mac/2026-11-12T08:00:00Z` as a date and time for people.
    static func date(_ snapshot: String) -> String {
        guard let time = snapshot.split(separator: "/").last, let date = ISO8601DateFormatter().date(from: String(time)) else { return snapshot }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
