import Foundation

/// Decides when the owner has to be told that backups are not happening: after three failed
/// runs in a row, and after three days without a successful one. Each is said once, until a
/// run has succeeded again. Skipped runs are not failures, so a Mac away from the server for
/// a weekend stays quiet. A failed run is tried again before the interval is over, with a
/// longer wait each time (`State.nextRun`), so three in a row are most of an hour of failing
/// unless backups are made more often than that.
public struct Notices: Codable, Equatable {
    public struct Notice: Equatable {
        public let title: String
        public let body: String
    }

    /// The end of the last successful run at the time each notice was posted; a later success
    /// makes the notice possible again.
    var failingReportedAfter: Date?
    var staleReportedAfter: Date?

    public init() {}

    /// The notice to post now, if any. Calling it again with the same state returns nil.
    public mutating func check(_ state: State, now: Date = Date()) -> Notice? {
        let lastSuccess = state.lastSuccess?.end ?? .distantPast
        if state.consecutiveFailures >= 3, failingReportedAfter != lastSuccess {
            failingReportedAfter = lastSuccess
            let reason = state.last?.reason.map { " " + $0 } ?? ""
            return Notice(title: "Backups are failing", body: "The last \(state.consecutiveFailures) backups failed.\(reason)")
        }
        // Without any success yet, the clock starts with the first run on record.
        guard let since = state.lastSuccess?.end ?? state.history.first?.start,
              now.timeIntervalSince(since) > 3 * 86400, staleReportedAfter != lastSuccess else { return nil }
        staleReportedAfter = lastSuccess
        let when = state.lastSuccess.map { "The last backup was on \($0.end.formatted(date: .abbreviated, time: .shortened))." }
            ?? "No backup has succeeded yet."
        return Notice(title: "No backup for three days", body: when)
    }
}
