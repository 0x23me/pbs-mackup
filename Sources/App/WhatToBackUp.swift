import AppKit
import PBSMackupKit
import SwiftUI

private func size(_ bytes: Int64) -> String {
    bytes <= 0 ? "nothing" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// The folders that are backed up with what is in them, largest first, to untick what is not
/// needed; beside it what is usually not worth keeping, and the rules made so far.
struct WhatToBackUpView: View {
    @ObservedObject var model: SettingsModel
    @State private var pattern = ""

    static let intervals: [(minutes: Int, title: String)] = [
        (15, "15 minutes"), (30, "30 minutes"), (60, "hour"), (120, "2 hours"), (240, "4 hours"),
        (720, "12 hours"), (1440, "day"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(alignment: .top, spacing: 16) {
                folders
                VStack(alignment: .leading, spacing: 14) {
                    suggestions
                    rules
                }
                .frame(width: 300)
            }
            Text(footnote).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: How much

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                if model.measured.isEmpty {
                    Text(model.measuring.isEmpty ? "Not measured yet" : "Measuring…").font(.title2.weight(.semibold))
                } else {
                    Text("\(size(model.tally.backedUp)) to back up").font(.title2.weight(.semibold))
                    Text("of \(size(model.tally.total))").font(.title3).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Back up every", selection: $model.intervalMinutes) {
                    ForEach(WhatToBackUpView.intervals, id: \.minutes) { Text($0.title).tag($0.minutes) }
                }
                .fixedSize()
            }
            if !model.measured.isEmpty {
                ShareBar(parts: [(model.tally.backedUp, Color.accentColor), (model.tally.byRules, Color.orange),
                                 (model.tally.automatic, Color.secondary.opacity(0.35))])
                    .frame(height: 10)
                HStack(spacing: 16) {
                    Legend(color: .accentColor, text: "Backed up")
                    Legend(color: .orange, text: "Left out by you: \(size(model.tally.byRules))")
                    Legend(color: .secondary.opacity(0.35), text: "Left out automatically: \(size(model.tally.automatic))")
                    Spacer()
                    if model.tally.shared > 0 {
                        Text("\(size(model.tally.shared)) of it are copies that take no extra room")
                            .help("Copies that macOS made without duplicating the data. The server stores such data once.")
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: The folders

    private var folders: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Largest first. Untick what you do not need.").font(.headline)
                Spacer()
                if !model.measuring.isEmpty { ProgressView().controlSize(.small) }
                Button { model.sources.forEach(model.measure) } label: { Label("Measure Again", systemImage: "arrow.clockwise") }
                    .disabled(!model.measuring.isEmpty)
                    .help(measuredHelp)
            }
            List {
                ForEach(model.sources, id: \.self) { source in
                    DisclosureGroup(isExpanded: expansion(source)) {
                        if let rows = model.rows[source] {
                            ItemRows(items: rows, whole: max(1, model.measured[source]?.root.bytes ?? 1), model: model)
                        } else {
                            Text(model.measuring.contains(source) ? "Measuring. This reads the size of every file once and takes about a minute for a home folder."
                                                                  : "Not measured.")
                                .foregroundStyle(.secondary)
                        }
                    } label: {
                        SourceRow(source: source, bytes: model.measured[source]?.root.bytes) { model.remove(source: source) }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            HStack {
                Button("Add Folder…") { model.addFolders() }
                if !model.sources.contains(NSHomeDirectory()) {
                    Button("Add Whole Home Folder") { model.add(source: NSHomeDirectory()) }
                }
                Spacer()
                Text(model.message).font(.callout).foregroundStyle(.red).lineLimit(2)
            }
        }
    }

    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(get: { model.expanded.contains(id) },
                set: { if $0 { model.expanded.insert(id) } else { model.expanded.remove(id) } })
    }

    private var measuredHelp: String {
        guard let oldest = model.measured.values.map(\.measured).min() else { return "Measure the folders" }
        return "Measured \(oldest.formatted(.relative(presentation: .named)))"
    }

    // MARK: Suggestions and rules

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Can be made or downloaded again").font(.headline)
            if model.suggestions.isEmpty {
                Text(model.measured.isEmpty ? "Shown once the folders are measured." : "Nothing more found.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.suggestions) { suggestion in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(suggestion.title).lineLimit(1).truncationMode(.middle)
                                    Text(suggestion.detail).font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 4)
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(size(suggestion.bytes)).monospacedDigit()
                                    Button("Leave Out") { model.add(rule: suggestion.rule) }.controlSize(.small)
                                }
                            }
                            .padding(.vertical, 6).padding(.horizontal, 8)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 250)
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            }
        }
    }

    private var rules: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Left out by you").font(.headline)
            ScrollView {
                VStack(spacing: 0) {
                    if model.rules.isEmpty {
                        Text("Nothing yet.").font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    ForEach(model.rules, id: \.self) { rule in
                        HStack(spacing: 6) {
                            Image(systemName: LeaveOut.path(of: rule) == nil ? "textformat.abc" : "folder")
                                .foregroundStyle(.secondary).frame(width: 18)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(title(of: rule)).lineLimit(1).truncationMode(.head)
                                if LeaveOut.path(of: rule) == nil {
                                    Text(rule.contains("/") ? "pattern" : "wherever it is").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 4)
                            Button { model.rules.removeAll { $0 == rule } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).help("Back this up again")
                        }
                        .padding(.vertical, 4).padding(.horizontal, 8)
                        Divider()
                    }
                }
            }
            .frame(minHeight: 60, maxHeight: .infinity)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            HStack(spacing: 6) {
                TextField("Name or pattern, e.g. *.iso", text: $pattern)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addPattern)
                Button(action: addPattern) { Image(systemName: "plus") }.disabled(pattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Button("Leave Out a Folder or File…") { model.leaveOutChosen() }
        }
    }

    private func addPattern() {
        model.add(rule: pattern)
        pattern = ""
    }

    /// A rule for one item reads as its path; with a home folder as the only source, from `~`.
    private func title(of rule: String) -> String {
        guard let path = LeaveOut.path(of: rule) else { return rule }
        if model.sources == [NSHomeDirectory()] { return "~/" + path }
        return path
    }

    private var footnote: String {
        var text = "Always left out: caches, the Trash, what apps mark as not worth backing up (the same mark Time Machine obeys), and files that are only in iCloud"
        let cloud = model.measured.values.reduce(0) { $0 + $1.cloudOnly }
        if cloud > 0 { text += " (\(size(cloud)) here)" }
        return text + "."
    }
}

/// The rows of one folder; a folder with listed contents opens to the same again.
private struct ItemRows: View {
    let items: [LeaveOut.Item]
    /// The size of the backed-up folder the rows belong to; the bars are shares of it.
    let whole: Int64
    @ObservedObject var model: SettingsModel

    var body: some View {
        ForEach(items) { item in
            if let children = item.children {
                DisclosureGroup(isExpanded: Binding(
                    get: { model.expanded.contains(item.id) },
                    set: { if $0 { model.expanded.insert(item.id) } else { model.expanded.remove(item.id) } })) {
                    ItemRows(items: children, whole: whole, model: model)
                } label: {
                    ItemRow(item: item, whole: whole) { model.toggle(item) }
                }
            } else {
                ItemRow(item: item, whole: whole) { model.toggle(item) }
            }
        }
    }
}

private struct ItemRow: View {
    let item: LeaveOut.Item
    let whole: Int64
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if item.state == .smaller {
                Color.clear.frame(width: 16, height: 16)
                Text("Smaller items").foregroundStyle(.secondary)
            } else {
                Button(action: toggle) {
                    Image(systemName: box).foregroundStyle(canToggle ? Color.accentColor : Color.secondary.opacity(0.6))
                }
                .buttonStyle(.plain).disabled(!canToggle).help(help)
                Image(systemName: item.isFolder ? "folder" : "doc").foregroundStyle(.secondary).frame(width: 18)
                Text(item.name).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(isOut ? .secondary : .primary)
            }
            Spacer(minLength: 8)
            if let note { Text(note).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
            ShareBar(parts: [(item.backedUp, Color.accentColor), (item.bytes - item.backedUp, Color.secondary.opacity(0.35))],
                     of: whole)
                .frame(width: 70, height: 6)
            Text(size(item.bytes)).monospacedDigit().foregroundStyle(isOut ? .secondary : .primary)
                .frame(width: 78, alignment: .trailing)
        }
    }

    private var isOut: Bool {
        switch item.state {
        case .leftOut, .automatic: true
        default: false
        }
    }

    private var canToggle: Bool {
        switch item.state {
        case .included, .partly, .leftOut(_, own: true): true
        default: false
        }
    }

    /// Something is left out of nearly every folder (a .DS_Store); only a share worth
    /// knowing about shows.
    private var partly: Bool { item.state == .partly && item.bytes - item.backedUp >= FolderSizes.smallest }

    private var box: String {
        switch item.state {
        case .included: "checkmark.square.fill"
        case .partly: partly ? "minus.square.fill" : "checkmark.square.fill"
        default: "square"
        }
    }

    private var note: String? {
        switch item.state {
        case .partly: partly ? "\(size(item.bytes - item.backedUp)) left out" : nil
        case .leftOut(let rule, own: false) where LeaveOut.path(of: rule) == nil: "left out as \(rule)"
        case .automatic(.timeMachine): "marked by its app"
        case .automatic(.always): "always left out"
        case .automatic(.otherVolume): "another volume"
        case .automatic(.cloudOnly): "only in iCloud"
        default: nil
        }
    }

    private var help: String {
        switch item.state {
        case .included, .partly: "Leave this out of the backup"
        case .leftOut(_, own: true): "Back this up again"
        case .leftOut(let rule, own: false):
            LeaveOut.path(of: rule) == nil ? "Left out by the rule \(rule); remove it on the right to back this up"
                                           : "Inside a folder that is left out"
        case .automatic(.timeMachine): "The app this belongs to marked it as not worth backing up"
        default: "Never backed up"
        }
    }
}

private struct SourceRow: View {
    let source: String
    let bytes: Int64?
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: source == NSHomeDirectory() ? "house" : "folder.fill").foregroundStyle(Color.accentColor).frame(width: 18)
            Text((source as NSString).abbreviatingWithTildeInPath).fontWeight(.medium)
            if source == NSHomeDirectory() { Text("your home folder").foregroundStyle(.secondary) }
            Spacer()
            if let bytes { Text(size(bytes)).monospacedDigit().foregroundStyle(.secondary) }
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).help("Stop backing up this folder")
        }
    }
}

/// A bar divided into coloured shares; of the sum of its parts, or of `of` when given.
private struct ShareBar: View {
    let parts: [(bytes: Int64, color: Color)]
    var of: Int64?

    var body: some View {
        GeometryReader { geometry in
            let whole = Double(max(1, of ?? parts.reduce(0) { $0 + $1.bytes }))
            HStack(spacing: 0) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    part.color.frame(width: geometry.size.width * Double(max(0, part.bytes)) / whole)
                }
                Spacer(minLength: 0)
            }
            .background(Color.secondary.opacity(0.12))
            .clipShape(Capsule())
        }
    }
}

private struct Legend: View {
    let color: Color
    let text: String
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
        }
    }
}
