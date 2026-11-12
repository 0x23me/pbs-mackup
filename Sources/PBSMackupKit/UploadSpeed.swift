import Foundation

/// The upload speed of a running backup, from the client's count of bytes sent. The count
/// moves in steps of whole chunks (a few megabytes), so the speed is taken over the last
/// seconds and not between two readings, which would jump between nothing and a burst.
public struct UploadSpeed {
    private var readings: [(time: Double, bytes: Int64)] = []
    /// How far back the speed looks.
    static let window = 10.0

    public init() {}

    /// Takes a reading (`time` in seconds since the backup began) and returns the speed in
    /// bits per second, or nil while there is too little to go by.
    public mutating func add(bytes: Int64, at time: Double) -> Double? {
        // A count that went back is a new upload; start over.
        if let last = readings.last, bytes < last.bytes || time < last.time { readings = [] }
        readings.append((time, bytes))
        // Keep one reading from before the window, so the window is always spanned.
        while readings.count > 2, readings[1].time <= time - UploadSpeed.window { readings.removeFirst() }
        guard let first = readings.first, time - first.time >= 2 else { return nil }
        return Double(bytes - first.bytes) * 8 / (time - first.time)
    }

    /// As text for the menu: gigabits per second from a tenth of one up, megabits below;
    /// nil when next to nothing is being sent, which is what reading unchanged files looks like.
    public static func text(_ bitsPerSecond: Double) -> String? {
        let megabits = bitsPerSecond / 1_000_000
        if megabits < 0.5 { return nil }
        if megabits < 100 { return String(format: megabits < 10 ? "%.1f Mbit/s" : "%.0f Mbit/s", megabits) }
        return String(format: megabits < 10_000 ? "%.2f Gbit/s" : "%.1f Gbit/s", megabits / 1000)
    }
}
