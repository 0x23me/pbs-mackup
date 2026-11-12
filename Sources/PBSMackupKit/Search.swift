import Foundation

/// The names of everything in one snapshot, to search by name without asking the server on
/// every keystroke. Built once per snapshot from the client's recursive listing and kept in
/// the cache; snapshots do not change.
public struct SnapshotIndex: Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public let archive: String
        /// Relative to the archive root.
        public let path: String
        public let type: String
        public let mtime: Int64
        public let size: Int64?
        public init(archive: String, path: String, type: String, mtime: Int64, size: Int64?) {
            self.archive = archive; self.path = path; self.type = type; self.mtime = mtime; self.size = size
        }
    }

    public let items: [Item]
    /// The paths without case and accents, as bytes, and where the name starts in each.
    private let folded: [[UInt8]]
    private let nameStart: [Int]

    public init(items: [Item]) {
        self.items = items
        folded = items.map { SnapshotIndex.fold($0.path) }
        nameStart = folded.map { ($0.lastIndex(of: UInt8(ascii: "/")) ?? -1) + 1 }
    }

    public init(contentsOf file: URL) throws {
        self.init(items: try JSONDecoder().decode([Item].self, from: Data(contentsOf: file)))
    }

    /// Lower case, no accents, one form for composed and decomposed letters.
    static func fold(_ text: String) -> [UInt8] {
        Array(text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).utf8)
    }

    /// The items that match every word of `query`, best first, and how many matched in all.
    ///
    /// A word matches when the name contains it, when the folders above contain it, or when the
    /// name has its letters in that order with little in between ("invpdf" finds
    /// "Invoice 2026.pdf"). Names that start with the word come first, then names where it
    /// starts a part, then the rest; among equals the shorter path wins.
    public func search(_ query: String, limit: Int = 500) -> (items: [Item], total: Int) {
        let words = query.split(whereSeparator: \.isWhitespace).map { SnapshotIndex.fold(String($0)) }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return ([], 0) }
        var found: [(score: Int, index: Int)] = []
        for index in items.indices {
            if let score = SnapshotIndex.score(words, path: folded[index], nameStart: nameStart[index]) {
                found.append((score, index))
            }
        }
        found.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if folded[a.index].count != folded[b.index].count { return folded[a.index].count < folded[b.index].count }
            return items[a.index].path < items[b.index].path
        }
        return (found.prefix(limit).map { items[$0.index] }, found.count)
    }

    static func score(_ words: [[UInt8]], path: [UInt8], nameStart: Int) -> Int? {
        var total = 0
        for word in words {
            if let at = find(word, in: path, from: nameStart) {
                let startsPart = at == nameStart || !isLetterOrDigit(path[at - 1])
                total += 100 + (at == nameStart ? 40 : startsPart ? 20 : 0) + (word.count == path.count - nameStart ? 30 : 0)
            } else if find(word, in: path, from: 0) != nil {
                total += 60
            } else if word.count >= 3, let between = lettersInOrder(word, in: path, from: nameStart), between <= 24 {
                total += 40 - between
            } else {
                return nil
            }
        }
        return total
    }

    /// Where `word` starts in `text` at or after `from`.
    static func find(_ word: [UInt8], in text: [UInt8], from: Int) -> Int? {
        guard !word.isEmpty, text.count - from >= word.count else { return nil }
        let first = word[0]
        var at = from
        let last = text.count - word.count
        while at <= last {
            if text[at] == first {
                var matched = 1
                while matched < word.count && text[at + matched] == word[matched] { matched += 1 }
                if matched == word.count { return at }
            }
            at += 1
        }
        return nil
    }

    /// How many other bytes lie between the letters of `word` when they appear in this order
    /// in `text` at or after `from`; nil when they do not.
    static func lettersInOrder(_ word: [UInt8], in text: [UInt8], from: Int) -> Int? {
        var next = 0, first = -1, at = from
        while at < text.count && next < word.count {
            if text[at] == word[next] {
                if next == 0 { first = at }
                next += 1
            }
            at += 1
        }
        guard next == word.count else { return nil }
        return (at - first) - word.count
    }

    static func isLetterOrDigit(_ byte: UInt8) -> Bool {
        byte >= 0x80 || (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x7a) || (byte >= 0x41 && byte <= 0x5a)
    }
}

extension Client {
    /// Where the index of a snapshot is kept.
    public static func indexFile(snapshot: String) -> URL {
        let name = snapshot.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        return Paths.index.appendingPathComponent(name + ".json")
    }

    /// Writes the names of everything in these archives of a snapshot into the cache, unless
    /// that was done before, and returns the file. Only names, sizes and dates are fetched.
    public func index(snapshot: String, archives: [String]) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: Paths.index, withIntermediateDirectories: true)
        // An index stays valid, but there is one per snapshot: those not used for two weeks go.
        for old in (try? manager.contentsOfDirectory(at: Paths.index, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let used = try? old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               used < Date().addingTimeInterval(-14 * 86400) {
                try? manager.removeItem(at: old)
            }
        }
        let file = Client.indexFile(snapshot: snapshot)
        if manager.fileExists(atPath: file.path) {
            try? manager.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return file
        }
        struct Listed: Decodable { let path: String, type: String, mtime: Int64, size: Int64? }
        var items: [SnapshotIndex.Item] = []
        let decoder = JSONDecoder()
        for archive in archives {
            let lines = try capture(["catalog", "list", snapshot, archive, "--recursive", "true"])
            for line in lines.split(separator: UInt8(ascii: "\n")) {
                let entry = try decoder.decode(Listed.self, from: Data(line))
                items.append(.init(archive: archive, path: entry.path, type: entry.type, mtime: entry.mtime, size: entry.size))
            }
        }
        try JSONEncoder().encode(items).write(to: file, options: .atomic)
        // File names are private; the cache folder is the owner's, the file is too.
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }
}
