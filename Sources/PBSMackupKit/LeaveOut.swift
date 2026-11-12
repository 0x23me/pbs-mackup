import Darwin
import Foundation

/// The owner's rules for what to leave out, as the client takes them (`.pxarexclude` patterns),
/// and what they mean for a measured folder. A rule that starts with a slash names one item
/// below the backed-up folder; a rule without a slash is a name that is left out wherever it is.
public enum LeaveOut {
    /// The rule that leaves out exactly this item; `relative` is its path below the backed-up folder.
    public static func rule(forPath relative: String) -> String {
        var rule = "/"
        for character in relative {
            if "*?[\\".contains(character) { rule.append("\\") }
            rule.append(character)
        }
        return rule
    }

    /// The path a rule names, when it is a rule for exactly one item.
    public static func path(of rule: String) -> String? {
        guard rule.hasPrefix("/") else { return nil }
        var path = "", escaped = false
        for character in rule.dropFirst() {
            if escaped { path.append(character); escaped = false }
            else if character == "\\" { escaped = true }
            else if "*?[".contains(character) { return nil }
            else { path.append(character) }
        }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Whether `rule` leaves out the item at `relative`. Close to what the client does; rules
    /// with `**` are judged loosely and rules that start with `!` (keep after all) never match.
    public static func matches(_ rule: String, relative: String) -> Bool {
        if rule.hasPrefix("!") || rule.isEmpty { return false }
        var pattern = rule.hasSuffix("/") ? String(rule.dropLast()) : rule
        let flags = pattern.contains("**") ? 0 : FNM_PATHNAME
        if pattern.hasPrefix("/") {
            pattern.removeFirst()
            return fnmatch(pattern, relative, flags) == 0
        }
        // Not tied to the top: it may match the end of the path at any folder boundary.
        var rest = Substring(relative)
        while true {
            if fnmatch(pattern, String(rest), flags) == 0 { return true }
            guard let slash = rest.firstIndex(of: "/") else { return false }
            rest = rest[rest.index(after: slash)...]
        }
    }

    public enum State: Equatable, Sendable {
        case included
        /// Included, with something left out below it.
        case partly
        /// Left out by one of the owner's rules; `own` when the rule is for exactly this item.
        case leftOut(rule: String, own: Bool)
        /// Left out by the backup itself.
        case automatic(FolderSizes.Reason)
        /// Stands for everything in a folder that is too small to be listed.
        case smaller
    }

    /// One row of the list of what is in a backed-up folder.
    public struct Item: Identifiable, Equatable, Sendable {
        /// The backed-up folder and the path below it.
        public let id: String
        public let source: String
        public let relative: String
        public let name: String
        public let isFolder: Bool
        public let bytes: Int64
        /// What of it goes into a backup.
        public let backedUp: Int64
        public let state: State
        public let children: [Item]?
    }

    /// What the rules add up to for one or more measured folders.
    public struct Tally: Equatable, Sendable {
        public var backedUp: Int64 = 0
        public var byRules: Int64 = 0
        public var automatic: Int64 = 0
        /// Of `backedUp`, what copies share with their originals and the server stores once.
        public var shared: Int64 = 0
        public var total: Int64 { backedUp + byRules + automatic }
        public init(backedUp: Int64 = 0, byRules: Int64 = 0, automatic: Int64 = 0, shared: Int64 = 0) {
            self.backedUp = backedUp; self.byRules = byRules; self.automatic = automatic; self.shared = shared
        }
    }

    /// The rows for a measured folder, largest first, with what the rules do to each.
    public static func items(_ sizes: FolderSizes, rules: [String]) -> [Item] {
        children(of: sizes.root, source: sizes.path, relative: "", rules: rules, inherited: nil)
    }

    public static func tally(_ sizes: FolderSizes, rules: [String]) -> Tally {
        let rows = items(sizes, rules: rules)
        var tally = Tally()
        tally.automatic = sizes.root.leftOut
        tally.backedUp = rows.reduce(0) { $0 + $1.backedUp }
        tally.byRules = sizes.root.bytes - tally.automatic - tally.backedUp
        tally.shared = min(sizes.root.shared, tally.backedUp)
        return tally
    }

    private static func children(of node: FolderSizes.Node, source: String, relative: String, rules: [String],
                                 inherited: State?) -> [Item] {
        var rows: [Item] = []
        var listed: Int64 = 0, listedLeftOut: Int64 = 0
        for child in node.children {
            listed += child.bytes
            listedLeftOut += child.leftOut
            let path = relative.isEmpty ? child.name : relative + "/" + child.name
            var state = inherited
            if state == nil, let reason = child.reason { state = .automatic(reason) }
            if state == nil, let rule = rules.first(where: { matches($0, relative: path) }) {
                state = .leftOut(rule: rule, own: LeaveOut.path(of: rule) == path)
            }
            // Below something that is left out, everything is, by the same rule but not its own.
            var below = state
            if case .leftOut(let rule, _) = state { below = .leftOut(rule: rule, own: false) }
            let rows2 = child.isFolder && !child.children.isEmpty
                ? children(of: child, source: source, relative: path, rules: rules, inherited: below) : nil
            var backedUp: Int64 = 0
            if state == nil {
                // What is listed below says what it keeps; what is too small to be listed is kept.
                backedUp = rows2.map { $0.reduce(0) { $0 + $1.backedUp } } ?? (child.bytes - child.leftOut)
                state = backedUp < child.bytes ? .partly : .included
            }
            rows.append(Item(id: source + "\u{0}" + path, source: source, relative: path, name: child.name,
                             isFolder: child.isFolder, bytes: child.bytes, backedUp: backedUp, state: state!, children: rows2))
        }
        // Everything too small to be listed, as one row. None of it is left out by itself
        // beyond what `leftOut` says, and rules are not looked up for it.
        let rest = node.bytes - listed
        if rest > 0, !node.children.isEmpty || relative.isEmpty {
            let restLeftOut = max(0, node.leftOut - listedLeftOut)
            rows.append(Item(id: source + "\u{0}" + relative + "\u{0}smaller", source: source, relative: relative,
                             name: "", isFolder: false, bytes: rest,
                             backedUp: inherited == nil ? rest - min(rest, restLeftOut) : 0, state: .smaller, children: nil))
        }
        return rows
    }
}

extension Suggestions {
    /// Something that could be left out, with what that saves.
    public struct Suggestion: Identifiable, Equatable, Sendable {
        public var id: String { rule }
        public let rule: String
        public let title: String
        public let detail: String
        public let bytes: Int64
    }

    static let nameNotes: [String: String] = [
        "node_modules": "JavaScript packages; npm install brings them back",
        "DerivedData": "Xcode build results",
        ".build": "Swift build results",
        ".venv": "Python environments", "venv": "Python environments",
        "__pycache__": "compiled Python files",
        ".gradle": "Gradle caches and build results",
        ".terraform": "Terraform providers; terraform init brings them back",
        "Pods": "CocoaPods packages; pod install brings them back",
        ".next": "Next.js build results", ".nuxt": "Nuxt build results",
        ".tox": "Python test environments", ".direnv": "direnv environments",
        ".mypy_cache": "type checker cache", ".pytest_cache": "test cache", ".ruff_cache": "linter cache",
    ]

    /// Places in a home folder that hold what can be downloaded or made again, or that are
    /// large and change all the time.
    static let places: [(path: String, title: String, note: String)] = [
        (".npm", "npm downloads", "npm fetches them again"),
        (".cache", "Caches of command line tools", ""),
        (".cargo/registry", "Rust crate downloads", "cargo fetches them again"),
        (".rustup/toolchains", "Rust toolchains", "rustup installs them again"),
        ("go/pkg", "Go module downloads", "go fetches them again"),
        (".m2/repository", "Maven downloads", ""),
        (".pnpm-store", "pnpm downloads", ""),
        ("Library/pnpm/store", "pnpm downloads", ""),
        (".bun/install/cache", "Bun downloads", ""),
        (".yarn/cache", "Yarn downloads", ""),
        (".cocoapods/repos", "CocoaPods catalogues", ""),
        (".pub-cache", "Dart and Flutter packages", ""),
        (".nuget/packages", "NuGet packages", ""),
        (".local/share/uv", "Python versions and tools from uv", ""),
        (".ollama/models", "Ollama models", "ollama pull downloads them again"),
        (".lmstudio/models", "LM Studio models", ""),
        (".docker", "Docker's local data", ""),
        (".colima", "Colima virtual machines", ""),
        (".lima", "Lima virtual machines", ""),
        (".minikube", "minikube clusters", ""),
        (".vagrant.d/boxes", "Vagrant boxes", ""),
        (".android/avd", "Android emulators", ""),
        ("Library/Android/sdk", "Android SDK", ""),
        ("Library/Developer/CoreSimulator", "iOS simulators", "Xcode downloads them again"),
        ("Library/Developer/Xcode/iOS DeviceSupport", "Debug symbols of connected devices", ""),
        ("Library/Developer/Toolchains", "Swift toolchains", "can be downloaded again"),
        ("Library/Containers/com.docker.docker", "Docker images and containers", ""),
        ("Library/Containers/com.utmapp.UTM", "UTM virtual machines", "not replaceable, but large, and a running one changes all the time"),
        ("Library/Application Support/Steam/steamapps", "Steam games", "Steam downloads them again"),
        ("Library/Logs", "Log files", ""),
    ]

    /// What could be left out of a measured folder, biggest saving first. Only what saves at
    /// least `atLeast` bytes and is not left out already.
    public static func find(in sizes: FolderSizes, rules: [String], atLeast: Int64 = 100 << 20) -> [Suggestion] {
        var found: [Suggestion] = []
        for (name, total) in sizes.names where total.bytes >= atLeast && !rules.contains(name) {
            let folders = total.count == 1 ? "1 folder" : "\(total.count) folders"
            found.append(.init(rule: name, title: "Folders named \(name)",
                               detail: [folders, nameNotes[name]].compactMap { $0 }.joined(separator: " · "), bytes: total.bytes))
        }
        let rows = LeaveOut.items(sizes, rules: rules)
        for place in places {
            var level = rows
            var row: LeaveOut.Item?
            for part in place.path.split(separator: "/") {
                row = level.first { $0.name == part && $0.state != .smaller }
                guard let next = row else { break }
                level = next.children ?? []
            }
            guard let row, row.relative == place.path, row.backedUp >= atLeast else { continue }
            let rule = LeaveOut.rule(forPath: place.path)
            if rules.contains(rule) { continue }
            found.append(.init(rule: rule, title: place.title,
                               detail: ["~/" + place.path, place.note].filter { !$0.isEmpty }.joined(separator: " · "),
                               bytes: row.backedUp))
        }
        return found.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.rule < $1.rule }
    }
}
