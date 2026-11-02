import Foundation

/// Weekly use of all accounts, booked per hour from successive snapshots and stored in history.json.
/// Units: pp is one percent of one account's weekly limit. Holds no secrets.
public struct UsageHistory: Codable, Sendable, Equatable {
    /// The last snapshot booked per account key (see `Identity.key`).
    public struct Reading: Codable, Sendable, Equatable {
        var asOf: Date
        var weekly: Double
        var reset: Date?
        var session: Double
        var sessionReset: Date?
    }

    /// Hour (seconds since 1970 / 3600) -> pp used in that hour by all accounts.
    public var hourly: [Int: Double] = [:]
    public var last: [String: Reading] = [:]
    /// Weekly pp and session percent used in the same session windows. Their ratio is the session size.
    public var sessionWeekly = 0.0, sessionPercent = 0.0
    /// The first booked snapshot.
    public var since: Date?
    /// When some use went unbooked: a reset passed more than 30 min after the account's last snapshot,
    /// or an account first seen more than 1 h after the history began had already used part of its week.
    /// The pace is a lower bound for 7 days after.
    public var gapAt: Date?

    public init() {}

    static let week: TimeInterval = 7 * 86400

    /// Weekly pp per full 5-hour session: 17 pp counted as 2 sessions, plus the measured pairs.
    public var sessionSize: Double { (sessionWeekly + 2 * 17) / (sessionPercent / 100 + 2) }

    /// Books the weekly use since the account's last snapshot. Snapshots not newer than the last one
    /// are ignored, so two sources of one account (its folder and ~/.claude) count each pp once.
    public mutating func add(_ snapshot: UsageSnapshot, key: String) {
        guard let weekly = snapshot.weekly else { return }
        let t = snapshot.asOf, reset = weekly.resetsAt
        let previous = last[key]
        if let previous, t <= previous.asOf { return }
        if previous == nil, weekly.percent > 0, let since, t.timeIntervalSince(since) > 3600 { gapAt = t }
        since = since ?? t
        var high = weekly.percent
        if let o = previous {
            if close(reset, o.reset) {
                let used = max(0, weekly.percent - o.weekly)
                high = max(weekly.percent, o.weekly)
                book(used, from: o.asOf, to: t)
                if snapshot.session?.resetsAt != nil, close(snapshot.session?.resetsAt, o.sessionReset) {
                    sessionWeekly += used
                    sessionPercent += max(0, (snapshot.session?.percent ?? 0) - o.session)
                }
            } else if o.reset.map({ $0 <= t }) ?? true {
                book(weekly.percent, from: max(o.asOf, (reset ?? t) - Self.week), to: t)
                if let r = o.reset, r.timeIntervalSince(o.asOf) > 30 * 60 { gapAt = t }
            }
            // Otherwise the reset moved before it passed: the snapshot is a new baseline.
        }
        last[key] = Reading(asOf: t, weekly: high, reset: reset, session: snapshot.session?.percent ?? 0,
                            sessionReset: snapshot.session?.resetsAt)
        let oldest = Self.hour(t) - 29 * 24
        hourly = hourly.filter { $0.key >= oldest }
    }

    /// Pool use per hour over the last 7 days. Nil before 7 days of history.
    public func pace(at now: Date) -> Double? {
        guard let since, now.timeIntervalSince(since) >= Self.week else { return nil }
        let first = Self.hour(now) - 167
        let hours = now.timeIntervalSince(Date(timeIntervalSince1970: Double(first) * 3600)) / 3600
        return hourly.filter { $0.key >= first }.values.reduce(0, +) / hours
    }

    /// True for 7 days after a gap: the pace misses some use.
    public func paceIsLowerBound(at now: Date) -> Bool { gapAt.map { now.timeIntervalSince($0) < Self.week } ?? false }

    /// Use per local hour of the week (slot 0 is Monday 0:00) over up to 4 weeks, scaled to a mean of 1.
    /// A slot is the mean of its hours, so a daylight-saving change does not distort it. The pattern is
    /// blended with a flat one: its weight is 0.67 after 1 week of history, 0.89 after 2, 0.97 after 4.
    public func pattern(at now: Date, calendar: Calendar = .current) -> [Double]? {
        guard let since else { return nil }
        let end = Self.hour(now), start = max(Self.hour(since) + 1, end - 28 * 24)
        let weeks = Double(end - start) / 168
        guard weeks >= 1 else { return nil }
        var sum = [Double](repeating: 0, count: 168), count = sum
        for h in start..<end {
            let slot = Self.slot(Date(timeIntervalSince1970: Double(h) * 3600), calendar)
            sum[slot] += hourly[h] ?? 0
            count[slot] += 1
        }
        let means = zip(sum, count).map { $1 > 0 ? $0 / $1 : 0 }
        let mean = means.reduce(0, +) / 168
        guard mean > 0 else { return nil }
        let weight = weeks / (weeks + 0.5 / weeks)
        return means.map { weight * $0 / mean + 1 - weight }
    }

    static func slot(_ date: Date, _ calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.weekday, .hour], from: date)
        return ((c.weekday ?? 2) + 5) % 7 * 24 + (c.hour ?? 0)
    }

    static func hour(_ date: Date) -> Int { Int((date.timeIntervalSince1970 / 3600).rounded(.down)) }

    /// Spreads `pp` over the hours that (start, end] covers, in proportion to the overlap.
    mutating func book(_ pp: Double, from start: Date, to end: Date) {
        guard pp > 0 else { return }
        let a = start.timeIntervalSince1970, b = end.timeIntervalSince1970
        guard b > a else { hourly[Self.hour(end), default: 0] += pp; return }
        for h in Self.hour(start)...Self.hour(end) {
            let overlap = min(b, Double(h + 1) * 3600) - max(a, Double(h) * 3600)
            if overlap > 0 { hourly[h, default: 0] += pp * overlap / (b - a) }
        }
    }

    private func close(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return abs(a.timeIntervalSince(b)) < 120
    }

    public static func load(from url: URL = Paths.historyFile) -> UsageHistory { JSONFile.load(from: url) ?? UsageHistory() }
    public func save(to url: URL = Paths.historyFile) throws { try JSONFile.save(self, to: url) }
}
