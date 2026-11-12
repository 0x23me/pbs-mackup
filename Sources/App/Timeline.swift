import AppKit
import PBSMackupKit
import SwiftUI

/// One line of the table: an entry of the open folder, or a search result from anywhere in
/// the snapshot.
struct Row: Identifiable, Equatable {
    /// Nil for the folders at the top of a snapshot, which are the archives themselves.
    let archive: String?
    /// The folders above the entry inside its archive.
    let folder: [String]
    let entry: Client.Entry

    var id: String { ([archive ?? ""] + folder + [entry.name]).joined(separator: "/") }
    var name: String { entry.name }
    var mtime: Int64 { entry.mtime }
    /// Relative to the archive root.
    var path: String { (folder + [entry.name]).joined(separator: "/") }
    /// Folders have no size; they go before every file.
    var sizeForSorting: Int64 { entry.size ?? -1 }
    /// Where a search result lies, e.g. "Downloads › Invoices".
    var place: String {
        ([archive.map { String($0.dropLast(".pxar".count)) }].compactMap { $0 } + folder).joined(separator: " › ")
    }
}

extension Row {
    init(_ hit: SnapshotIndex.Item) {
        var parts = hit.path.split(separator: "/").map(String.init)
        let name = parts.isEmpty ? hit.path : parts.removeLast()
        self.init(archive: hit.archive, folder: parts, entry: Client.Entry(name: name, type: hit.type, mtime: hit.mtime, size: hit.size))
    }
}

/// Browses the snapshots through the run tool.
@MainActor
final class TimelineModel: ObservableObject {
    @Published var snapshots: [Client.Snapshot] = []
    @Published var selected: Client.Snapshot.ID?
    /// Nil at the top of a snapshot, where its folders (archives) are listed.
    @Published var archive: String?
    @Published var path: [String] = []
    @Published var entries: [Client.Entry] = []
    @Published var selection = Set<Row.ID>()
    /// What is typed into the search field, and what it found in the selected snapshot; nil
    /// while not searching.
    @Published var query = ""
    @Published var hits: [Row]?
    @Published var busy = false
    @Published var message = ""
    /// The versions of `versionsOf`, while its sheet is open.
    @Published var versions: [Client.Version]?
    @Published var versionsOf = ""
    /// Set by clicking a column header; kept while moving between folders and snapshots.
    @Published var sortOrder = [KeyPathComparator(\Row.name, comparator: .localizedStandard)]
    /// Search results come best match first until a column header is clicked.
    @Published var hitSortOrder: [KeyPathComparator<Row>] = []
    @Published var versionSortOrder = [KeyPathComparator(\Client.Version.backedUp, order: .reverse)]

    var searching: Bool { hits != nil }
    /// What the table shows.
    var rows: [Row] {
        if let hits { return hitSortOrder.isEmpty ? hits : hits.sorted(using: hitSortOrder) }
        return entries.map { Row(archive: archive, folder: path, entry: $0) }.sorted(using: sortOrder)
    }
    var selectedRows: [Row] { rows.filter { selection.contains($0.id) } }
    /// The folders at the top of a snapshot are whole archives, which are not restored in one piece.
    func canRestore(_ ids: Set<Row.ID>) -> Bool {
        let chosen = rows.filter { ids.contains($0.id) }
        return !chosen.isEmpty && chosen.allSatisfy { $0.archive != nil }
    }
    var sortedVersions: [Client.Version] { (versions ?? []).sorted(using: versionSortOrder) }

    var snapshot: Client.Snapshot? { snapshots.first { $0.id == selected } }
    var location: String {
        if searching { return "Search results in this backup" }
        let place = ([archive.map { String($0.dropLast(".pxar".count)) }].compactMap { $0 } + path).joined(separator: " › ")
        return place.isEmpty ? "Folders in this backup" : place
    }

    /// Several things can be under way at once, e.g. two listings after two quick clicks.
    private var working = 0
    private func work(_ body: () async throws -> Void) async {
        working += 1
        busy = true
        defer { working -= 1; busy = working > 0 }
        do { try await body() } catch { message = "\(error)" }
    }

    private func fetchSnapshots() async throws -> [Client.Snapshot] {
        try await RunTool.decode([Client.Snapshot].self, ["snapshots"])
    }

    func loadSnapshots() async {
        let before = selected
        refreshed = Date()
        await work {
            snapshots = try await fetchSnapshots()
            message = snapshots.isEmpty ? "No backups yet." : ""
            if snapshot == nil { selected = snapshots.first?.id }
        }
        // A changed selection loads its entries by itself, see the view.
        if selected == before { await loadEntries() }
    }

    private var refreshed = Date.distantPast

    /// Picks up backups made while the window was open, when it comes to the front again.
    /// Quiet: no spinner, and no message when the server cannot be reached.
    func refreshSnapshots() async {
        guard Date().timeIntervalSince(refreshed) > 30 else { return }
        refreshed = Date()
        guard let fresh = try? await fetchSnapshots(), fresh != snapshots else { return }
        snapshots = fresh
        if snapshot == nil { selected = snapshots.first?.id }
    }

    /// Counts the listings asked for, so that a slow answer to an earlier question cannot
    /// replace the answer to a later one.
    private var listing = 0

    /// Lists the current folder in the selected snapshot. A folder that does not exist in that
    /// snapshot falls back to its nearest existing parent.
    func loadEntries() async {
        listing += 1
        let asked = listing
        guard let snapshot else { entries = []; return }
        selection = []
        await work {
            if let current = archive, !snapshot.archives.contains(current) { archive = nil; path = [] }
            while asked == listing {
                guard let archive else {
                    entries = snapshot.archives.map {
                        Client.Entry(name: String($0.dropLast(".pxar".count)), type: "directory",
                                     mtime: Int64(snapshot.time.timeIntervalSince1970), size: nil)
                    }
                    return
                }
                do {
                    let data = try await RunTool.call(["list", snapshot.name, archive, path.joined(separator: "/")])
                    guard asked == listing else { return }
                    entries = try JSONDecoder().decode([Client.Entry].self, from: data)
                    return
                } catch {
                    guard asked == listing else { return }
                    guard !path.isEmpty, "\(error)".contains("no such path") else { throw error }
                    path.removeLast()
                }
            }
        }
    }

    /// A folder is entered; a file is fetched from the backup into the cache and opened, to look at.
    func open(_ row: Row) async {
        guard row.entry.isDirectory else {
            guard let snapshot, let archive = row.archive else { return }
            await work {
                message = "Fetching \(row.name)…"
                let folder = Paths.preview.appendingPathComponent(UUID().uuidString)
                if let file = try await restore(row.path, from: snapshot.name, archive: archive, into: folder) {
                    message = "\(row.name) as of \(snapshot.time.formatted(date: .abbreviated, time: .shortened)), a copy to look at."
                    NSWorkspace.shared.open(file)
                }
            }
            return
        }
        if let inside = row.archive { archive = inside; path = row.folder + [row.name] } else { archive = row.name + ".pxar"; path = [] }
        endSearch()
        await loadEntries()
    }

    /// Goes to the folder a search result lies in and selects it there.
    func reveal(_ row: Row) async {
        guard let inside = row.archive else { return }
        archive = inside
        path = row.folder
        endSearch()
        await loadEntries()
        selection = [row.id]
    }

    // MARK: - Searching

    /// The names in the snapshots searched so far; a few thousand entries each, so only a few are kept.
    private var indexes: [Client.Snapshot.ID: SnapshotIndex] = [:]
    private var search: Task<Void, Never>?

    private func endSearch() {
        search?.cancel()
        query = ""
        if hits != nil { hits = nil; selection = []; message = "" }
    }

    /// Searches the selected snapshot for what is in the search field, a moment after the last
    /// keystroke. The whole snapshot is searched, not only the open folder.
    func runSearch() {
        search?.cancel()
        let words = query.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty, let snapshot else {
            if hits != nil { hits = nil; selection = []; message = "" }
            return
        }
        search = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await work {
                let index = try await index(of: snapshot)
                let found = await Task.detached(priority: .userInitiated) { index.search(words) }.value
                guard !Task.isCancelled else { return }
                hits = found.items.map(Row.init)
                selection = []
                if found.total == 0 {
                    message = "Nothing in this backup has a name like “\(words)”."
                } else if found.total > found.items.count {
                    message = "\(found.total) items match; the best \(found.items.count) are shown."
                } else {
                    message = found.total == 1 ? "1 item in this backup matches." : "\(found.total) items in this backup match."
                }
            }
        }
    }

    private func index(of snapshot: Client.Snapshot) async throws -> SnapshotIndex {
        if let known = indexes[snapshot.id] { return known }
        struct Indexed: Decodable { let index: String }
        message = "Reading the names in this backup…"
        let file = URL(fileURLWithPath: try await RunTool.decode(Indexed.self, ["index", snapshot.name] + snapshot.archives).index)
        let index = try await Task.detached { try SnapshotIndex(contentsOf: file) }.value
        if indexes.count >= 3 { indexes.removeAll() }
        indexes[snapshot.id] = index
        return index
    }

    private struct Restored: Decodable { let restored: String? }

    /// Nil when the item was skipped.
    private func restore(_ item: String, from snapshot: String, archive: String, into folder: URL,
                         conflict: Client.Conflict = .keepBoth) async throws -> URL? {
        let answer = try await RunTool.decode(Restored.self, ["restore", snapshot, archive, item, folder.path, conflict.rawValue])
        return answer.restored.map { URL(fileURLWithPath: $0) }
    }

    /// The folder an item came from on this Mac, if its top folder is still being backed up.
    private func originalFolder(of row: Row) -> URL? {
        guard let archive = row.archive, let source = (try? Config.load())?.sources
            .map({ ($0 as NSString).expandingTildeInPath }).first(where: { Config.archiveName(for: $0) == archive }) else { return nil }
        return row.folder.reduce(URL(fileURLWithPath: source)) { $0.appendingPathComponent($1) }
    }

    /// Asks what to do about an item that is already there. Nothing has been touched at this point.
    private func askAboutExisting(_ name: String, in folder: URL, more: Bool) -> (Client.Conflict, forAll: Bool) {
        let alert = NSAlert()
        alert.messageText = "“\(name)” already exists in \(folder.lastPathComponent)."
        alert.informativeText = "Replace it with the version from the backup, keep both, or leave this one out?"
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Skip")
        alert.showsSuppressionButton = more
        alert.suppressionButton?.title = "Do the same for the other items"
        let answer: Client.Conflict
        switch alert.runModal() {
        case .alertSecondButtonReturn: answer = .replace
        case .alertThirdButtonReturn: answer = .skip
        default: answer = .keepBoth
        }
        return (answer, alert.suppressionButton?.state == .on)
    }

    /// Shows the open folder of the selected snapshot in Finder, read-only. Without FUSE-T it
    /// says what is needed; everything else in this window works without it.
    func openInFinder() async {
        guard let snapshot, let archive else { return }
        guard Client.canMount else {
            let alert = NSAlert()
            alert.messageText = "Open in Finder needs FUSE-T"
            alert.informativeText = Client.fuseTNeeded
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Open fuse-t.org")
            if alert.runModal() == .alertSecondButtonReturn, let page = URL(string: "https://www.fuse-t.org") {
                NSWorkspace.shared.open(page)
            }
            return
        }
        struct Mounted: Decodable { let mounted: String }
        await work {
            message = "Opening the backup in Finder…"
            let root = URL(fileURLWithPath: try await RunTool.decode(Mounted.self, ["mount", snapshot.name, archive]).mounted)
            NSWorkspace.shared.open(path.reduce(root) { $0.appendingPathComponent($1) })
            message = "Opened read-only in Finder, as of \(snapshot.time.formatted(date: .abbreviated, time: .shortened)). "
                + "It goes away when this window closes."
        }
    }

    /// To the enclosing folder; out of the search results, back to the folder that was open.
    func up() async {
        if searching { endSearch(); return }
        if path.isEmpty { archive = nil } else { path.removeLast() }
        await loadEntries()
    }

    /// Asks where restored items should go.
    private func chooseFolder(for what: String, from date: Date) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Restore Here"
        panel.message = "Choose where to put \(what) from \(date.formatted(date: .abbreviated, time: .shortened))."
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Lists the states of one file across all snapshots, one row per change.
    func showVersions(of row: Row) async {
        guard let archive = row.archive, !row.entry.isDirectory else { return }
        versionsOf = row.path
        versionsArchive = archive
        versions = []
        await work {
            versions = try await RunTool.decode([Client.Version].self, ["versions", archive, versionsOf])
        }
    }

    private var versionsArchive = ""

    func restore(_ version: Client.Version) async {
        guard let folder = chooseFolder(for: (versionsOf as NSString).lastPathComponent, from: version.backedUp) else { return }
        await work {
            if let file = try await restore(versionsOf, from: version.snapshot, archive: versionsArchive, into: folder) {
                message = "Restored to \(file.path)."
                NSWorkspace.shared.activateFileViewerSelecting([file])
            }
        }
    }

    /// Restores the selected items: to where each came from, or into a folder the owner picks.
    /// An item that is already there is never touched without an answer to the question.
    func restoreSelection(toOriginal: Bool = false) async {
        let chosen = selectedRows
        guard let snapshot, !chosen.isEmpty, canRestore(selection) else { return }
        var picked: URL?
        if toOriginal {
            guard chosen.allSatisfy({ originalFolder(of: $0) != nil }) else {
                message = "The folder this came from is no longer among the folders being backed up. Use Restore… to choose where it goes."
                return
            }
        } else {
            picked = chooseFolder(for: chosen.count == 1 ? chosen[0].name : "\(chosen.count) items", from: snapshot.time)
            guard picked != nil else { return }
        }
        await work {
            var restored: [URL] = [], skipped = 0
            var forAll: Client.Conflict?
            for (index, row) in chosen.enumerated() {
                guard let archive = row.archive, let folder = picked ?? originalFolder(of: row) else { continue }
                var conflict = Client.Conflict.keepBoth
                if (try? folder.appendingPathComponent(row.name).checkResourceIsReachable()) == true {
                    if let decided = forAll { conflict = decided } else {
                        let answer = askAboutExisting(row.name, in: folder, more: index < chosen.count - 1)
                        conflict = answer.0
                        if answer.forAll { forAll = conflict }
                    }
                }
                message = "Restoring \(row.name)…"
                if let file = try await restore(row.path, from: snapshot.name, archive: archive, into: folder, conflict: conflict) {
                    restored.append(file)
                } else {
                    skipped += 1
                }
            }
            let folders = Set(restored.map { $0.deletingLastPathComponent().path })
            message = "Restored \(restored.count) item\(restored.count == 1 ? "" : "s")"
                + (folders.count == 1 ? " to \(folders.first!)" : folders.isEmpty ? "" : " to the folders they came from")
                + (skipped > 0 ? ", left out \(skipped)." : ".")
            if !restored.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(restored) }
        }
    }
}

struct TimelineView: View {
    @StateObject private var model = TimelineModel()

    var body: some View {
        NavigationSplitView {
            List(model.snapshots, selection: $model.selected) { snapshot in
                VStack(alignment: .leading) {
                    Text(snapshot.time.formatted(date: .abbreviated, time: .shortened))
                    Text(snapshot.time.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    Button { Task { await model.up() } } label: { Image(systemName: "chevron.up") }
                        .disabled(model.archive == nil && !model.searching)
                        .keyboardShortcut(.upArrow, modifiers: .command)
                        .help(model.searching ? "Back to the folder" : "Enclosing folder")
                    Text(model.location).lineLimit(1).truncationMode(.head)
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                    Button("Open in Finder") { Task { await model.openInFinder() } }
                        .disabled(model.archive == nil || model.searching || model.busy)
                    Button("Restore to Original Location") { Task { await model.restoreSelection(toOriginal: true) } }
                        .disabled(!model.canRestore(model.selection) || model.busy)
                    Button("Restore…") { Task { await model.restoreSelection() } }
                        .disabled(!model.canRestore(model.selection) || model.busy)
                }
                .padding(8)
                Divider()
                Table(model.rows, selection: $model.selection, sortOrder: Binding(
                    get: { model.searching ? model.hitSortOrder : model.sortOrder },
                    set: { if model.searching { model.hitSortOrder = $0 } else { model.sortOrder = $0 } })) {
                    TableColumn("Name", value: \.name, comparator: .localizedStandard) { row in
                        HStack(spacing: 8) {
                            Label(row.name, systemImage: row.entry.isDirectory ? "folder" : row.entry.type == "symlink" ? "arrow.up.right.square" : "doc")
                                .lineLimit(1).layoutPriority(1)
                            // A search result can be anywhere in the backup.
                            if model.searching {
                                Text(row.place).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            }
                        }
                    }
                    TableColumn("Size", value: \.sizeForSorting) { row in
                        Text(row.entry.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "")
                            .foregroundStyle(.secondary)
                    }.width(90)
                    TableColumn("Modified", value: \.mtime) { row in
                        Text(Date(timeIntervalSince1970: TimeInterval(row.mtime)).formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    }.width(160)
                }
                .overlay {
                    if model.entries.isEmpty && !model.busy && model.archive != nil && !model.searching {
                        Text("This folder is empty").foregroundStyle(.secondary)
                    }
                }
                .contextMenu(forSelectionType: Row.ID.self) { ids in
                    // The menu is about the rows that were clicked, which a right-click does not select.
                    Button("Restore to Original Location") {
                        model.selection = ids
                        Task { await model.restoreSelection(toOriginal: true) }
                    }.disabled(!model.canRestore(ids))
                    Button("Restore…") {
                        model.selection = ids
                        Task { await model.restoreSelection() }
                    }.disabled(!model.canRestore(ids))
                    if ids.count == 1, let row = model.rows.first(where: { ids.contains($0.id) }), row.archive != nil {
                        if !row.entry.isDirectory {
                            Button("Show Versions…") { Task { await model.showVersions(of: row) } }
                        }
                        if model.searching {
                            Button("Show in Enclosing Folder") { Task { await model.reveal(row) } }
                        }
                    }
                } primaryAction: { ids in
                    if let row = model.rows.first(where: { ids.contains($0.id) }) { Task { await model.open(row) } }
                }
                if !model.message.isEmpty {
                    Divider()
                    Text(model.message).font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 440)
        .searchable(text: $model.query, placement: .toolbar, prompt: "Search this backup")
        .modifier(FindShortcut())
        .onChange(of: model.query) { model.runSearch() }
        .sheet(isPresented: Binding(get: { model.versions != nil }, set: { if !$0 { model.versions = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Versions of \((model.versionsOf as NSString).lastPathComponent)").font(.headline)
                if model.busy && model.versions?.isEmpty == true {
                    ProgressView("Looking through the backups…")
                } else {
                    Table(model.sortedVersions, sortOrder: $model.versionSortOrder) {
                        TableColumn("Modified", value: \.modified) { version in
                            Text(Date(timeIntervalSince1970: TimeInterval(version.modified)).formatted(date: .abbreviated, time: .shortened))
                        }
                        TableColumn("Size", value: \.sizeForSorting) { version in
                            Text(version.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "")
                        }.width(90)
                        TableColumn("First backed up", value: \.backedUp) { version in
                            Text(version.backedUp.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                        }
                        TableColumn("") { version in
                            Button("Restore…") { Task { await model.restore(version) } }
                        }.width(90)
                    }
                }
                HStack {
                    Spacer()
                    Button("Done") { model.versions = nil }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(width: 620, height: 360)
        }
        .task { await model.loadSnapshots() }
        // What Open in Finder mounted lives as long as this window (and the app, see StatusModel).
        .onDisappear { DispatchQueue.global().async { Client.unmount() } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if (note.object as? NSWindow)?.title == "Backups" { DispatchQueue.global().async { Client.unmount() } }
        }
        .onChange(of: model.selected) {
            Task { await model.loadEntries() }
            model.runSearch()      // the same words, in the other backup
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if (note.object as? NSWindow)?.title == "Backups" { Task { await model.refreshSnapshots() } }
        }
    }
}

/// Command-F puts the cursor into the search field, where the system can do that.
private struct FindShortcut: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.searchFocused($focused).background {
                Button("Find") { focused = true }.keyboardShortcut("f", modifiers: .command).opacity(0).frame(width: 0, height: 0)
            }
        } else {
            content
        }
    }
}

/// Sorting by size needs a value where there is none; those rows go first.
extension Client.Version { var sizeForSorting: Int64 { size ?? -1 } }
