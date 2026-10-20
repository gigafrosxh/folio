import Foundation

/// Which dated copies (note versions, library backups) to keep: everything recent, then thinner and
/// thinner further back – newest copy per hour, per day, per week – and nothing older than `maxAge`.
public struct RetentionPolicy: Sendable, Equatable {
    /// Keep every copy younger than this.
    public var keepAll: TimeInterval
    /// Up to this age keep the newest copy per hour.
    public var hourly: TimeInterval
    /// Up to this age keep the newest copy per day.
    public var daily: TimeInterval
    /// Up to this age keep the newest copy per week; older copies are removed.
    public var maxAge: TimeInterval
    /// Hard cap on the number of copies (the newest are kept).
    public var maxCount: Int

    public init(keepAll: TimeInterval, hourly: TimeInterval, daily: TimeInterval, maxAge: TimeInterval, maxCount: Int) {
        self.keepAll = keepAll
        self.hourly = hourly
        self.daily = daily
        self.maxAge = maxAge
        self.maxCount = maxCount
    }

    static let hour: TimeInterval = 3600
    static let day: TimeInterval = 86_400

    /// Note versions: all of the last 24 hours, hourly for a week, daily for 3 months, weekly for a year.
    public static let versions = RetentionPolicy(keepAll: day, hourly: 7 * day, daily: 90 * day, maxAge: 365 * day, maxCount: 300)
    /// Library backups: all of the last 2 days, daily for 2 weeks, weekly for 3 months.
    public static let backups = RetentionPolicy(keepAll: 2 * day, hourly: 2 * day, daily: 14 * day, maxAge: 90 * day, maxCount: 30)

    /// The dates to delete. The newest copy is never deleted.
    public func toDelete(_ dates: [Date], now: Date = Date()) -> [Date] {
        let sorted = dates.sorted(by: >)
        guard let newest = sorted.first else { return [] }
        var keep: Set<Date> = [newest]
        var seenBuckets: Set<String> = []
        let calendar = Calendar(identifier: .gregorian)
        for date in sorted {
            let age = now.timeIntervalSince(date)
            let bucket: String
            if age < keepAll {
                keep.insert(date)
                continue
            } else if age < hourly {
                let c = calendar.dateComponents([.year, .month, .day, .hour], from: date)
                bucket = "h\(c.year!)-\(c.month!)-\(c.day!)-\(c.hour!)"
            } else if age < daily {
                let c = calendar.dateComponents([.year, .month, .day], from: date)
                bucket = "d\(c.year!)-\(c.month!)-\(c.day!)"
            } else if age < maxAge {
                let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
                bucket = "w\(c.yearForWeekOfYear!)-\(c.weekOfYear!)"
            } else {
                continue
            }
            // Dates are newest first, so the first copy seen in a bucket is its newest.
            if seenBuckets.insert(bucket).inserted { keep.insert(date) }
        }
        var kept = sorted.filter { keep.contains($0) }
        if kept.count > maxCount { kept = Array(kept.prefix(maxCount)) }
        let keptSet = Set(kept)
        return sorted.filter { !keptSet.contains($0) }
    }
}

/// Sortable, file-name-safe timestamps ("20261020T121314123Z").
public enum Stamp {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        return f
    }()

    public static func string(_ date: Date) -> String { formatter.string(from: date) }
    public static func date(_ string: String) -> Date? { formatter.date(from: String(string.prefix(19))) }
}
