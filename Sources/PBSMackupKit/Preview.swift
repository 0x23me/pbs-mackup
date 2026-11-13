import Foundation

extension Paths {
    /// Removes the files that were opened from a backup to look at. They are readable copies of
    /// what the backup keeps encrypted, so they go when the Backups window closes and when the
    /// app quits, and when it starts, for the time it did not get to.
    public static func emptyPreview() { removeRestored(preview) }
}
