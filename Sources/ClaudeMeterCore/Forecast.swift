import Foundation

/// The weekly room of all accounts over the next 7 days, used at the user's pace.
/// Units: pp is one percent of one account's weekly limit; a pace is pp per hour.
public struct Forecast: Sendable, Equatable {
    /// One account's weekly room. It is lost at the weekly reset, which refills it to 100 pp.
    struct Lot: Equatable {
        /// The account folders signed in to the account; the first has the newest snapshot.
        var ids: [UUID]
        var asOf: Date
        /// Weekly percent used.
        var used: Double
        var room = 100.0
        /// Nil when no reset in the next 7 days is known.
        var reset: Date?
        /// pp of weekly room used in the open 5-hour session window.
        var sessionUsed = 0.0
        var sessionEnd: Date?
        /// The snapshot is at most 30 min old and has no error.
        var fresh = false
        /// The known numbers leave at least 1 pp of weekly room and of session room.
        var available = false
        var usable: Bool { fresh && available }
    }

    /// The result of one simulation.
    public struct Outcome: Sendable, Equatable {
        /// The first step in which some use cannot be served.
        public var runOut: Date?
        /// pp of use not served in the 7 days.
        public var short = 0.0
        /// pp of room lost at weekly resets, and the last reset that loses more than 1 pp.
        public var unused = 0.0
        public var unusedBy: Date?
        public var runsOut: Bool { short > 5 }
    }

    /// A weekly reset, the most use that the accounts allow before it, and that use per day.
    public struct Refill: Sendable, Equatable {
        public var date: Date
        /// pp: the room now and the refills of earlier resets, each account giving at most one session's
        /// worth per 5 hours.
        public var room: Double
        /// pp per day: `room` over the days until `date`.
        public var perDay: Double
        /// The weekly resets before `date`. Their refills are part of `room`.
        public var refills: Int
    }

    public var accounts = 0
    public var left = 0.0
    /// The room left now if every account had been used at an even rate that reaches 100 % at its reset.
    public var steadyLeft = 0.0
    /// The weekly reset with the least room per day before it. Its `perDay` is the most use per day, on
    /// average, that runs short before no weekly reset in the next 7 days. A reset that refills little
    /// therefore does not hide a long wait for the next one.
    public var refill: Refill?
    /// The pool's use per hour over the last 7 days. A lower bound before 7 days of history.
    public var pace: Double?
    public var paceIsLowerBound = true
    /// The simulation at `pace`.
    public var outcome: Outcome?
    /// The last weekly reset in the next 7 days.
    public var lastReset: Date?
    /// The account to switch to. Nil when the account in use stays the best choice.
    public var next: UUID?
    /// No account is usable now, or the pool runs out within 24 h.
    public var alert = false

    public init() {}

    /// The forecast for the accounts' latest results. Empty until every account that is signed in has a
    /// snapshot: the measured pace covers all accounts, so a partial pool would run out too soon.
    public static func make(accounts: [Account], results: [UUID: ProbeResult], history: UsageHistory,
                            current: UUID?, now: Date, calendar: Calendar = .current) -> Forecast {
        let size = history.sessionSize
        func key(_ account: Account) -> String { account.identity?.key ?? account.id.uuidString }
        var lots: [String: Lot] = [:], order: [String] = []
        for account in accounts {
            guard let result = results[account.id] else { return Forecast() }
            guard !result.signedOut else { continue }
            guard let snapshot = result.snapshot else { return Forecast() }
            guard let weekly = snapshot.weekly else { continue }
            var lot = Lot(ids: [account.id], asOf: snapshot.asOf, used: weekly.percent)
            if var reset = weekly.resetsAt {
                if reset > now { lot.room = max(0, 100 - weekly.percent) }
                while reset <= now { (reset, lot.used) = (reset + UsageHistory.week, 0) }
                lot.reset = reset
            }
            if let session = snapshot.session, let end = session.resetsAt, end > now {
                (lot.sessionUsed, lot.sessionEnd) = (size * session.percent / 100, end)
            }
            lot.fresh = result.fresh(at: now) != nil
            lot.available = lot.room >= 1 && size - lot.sessionUsed >= 1
            if let other = lots[key(account)] {
                guard snapshot.asOf > other.asOf else { lots[key(account)]?.ids.append(account.id); continue }
                lot.ids += other.ids
            } else {
                order.append(key(account))
            }
            lots[key(account)] = lot
        }
        let pool = order.compactMap { lots[$0] }

        var f = Forecast()
        f.accounts = pool.count
        f.left = pool.reduce(0) { $0 + $1.room }
        f.steadyLeft = pool.reduce(0) { total, lot in
            total + (lot.reset.map { 100 * min(1, max(0, $0.timeIntervalSince(now) / UsageHistory.week)) } ?? 100)
        }
        f.lastReset = pool.compactMap(\.reset).max()
        let measured = history.pace(at: now)
        f.pace = measured ?? paceLowerBound(pool, now: now)
        f.paceIsLowerBound = measured == nil || history.paceIsLowerBound(at: now)
        let simulation = Simulation(lots: pool, start: now, sessionSize: size,
                                    pattern: history.pattern(at: now, calendar: calendar), calendar: calendar)
        f.outcome = f.pace.map { simulation.run(pace: $0) }
        let served = simulation.capacity()
        f.refill = pool.compactMap { lot -> Refill? in
            guard let reset = lot.reset else { return nil }
            let j = Int((reset.timeIntervalSince(now) / Simulation.step).rounded(.up))
            guard j >= 1, j <= Simulation.steps else { return nil }
            let days = max(Simulation.step, reset.timeIntervalSince(now)) / 86400
            let refills = pool.filter { $0.reset.map { $0 < reset } ?? false }.count
            return Refill(date: reset, room: served[j], perDay: served[j] / days, refills: refills)
        }.min { $0.perDay < $1.perDay }

        // The account in use stays while its numbers leave room, even when its last probe failed.
        let inUse = accounts.first { $0.id == current }.flatMap { lots[key($0)] }
        let rho = { (lot: Lot) in simulation.rho(lot, step: 0) }
        if let best = pool.filter(\.usable).max(by: { rho($0) < rho($1) }), best.ids != inUse?.ids,
           !(inUse?.available == true && rho(best) < 1.5 * (inUse.map(rho) ?? 0)) {
            f.next = best.ids.first
        }
        let blocked = !pool.isEmpty && pool.allSatisfy { !$0.available }
        let soon = f.outcome.flatMap { $0.runsOut ? $0.runOut : nil }.map { $0 < now + 86400 } ?? false
        f.alert = blocked || soon
        return f
    }

    /// A lower bound on the pool's use per hour since the oldest open weekly window began, at most 7 days
    /// ago: all weekly use in the open windows, over that window's age. Nil while it is younger than 24 h.
    static func paceLowerBound(_ lots: [Lot], now: Date) -> Double? {
        let dated = lots.filter { $0.reset != nil }
        guard let oldest = dated.compactMap(\.reset).min() else { return nil }
        let age = (now.timeIntervalSince(oldest) + UsageHistory.week) / 3600
        return age >= 24 ? dated.reduce(0) { $0 + $1.used } / age : nil
    }
}

/// The next 7 days in 10-minute steps. Each step's use goes to the accounts in order of highest ρ,
/// each giving at most its weekly room and what is left of its 5-hour session. A session window opens
/// at the first use after the previous one ended and gives at most `sessionSize` pp. Resets and session
/// ends take effect at the first step on or after them.
struct Simulation {
    static let step: TimeInterval = 600
    static let steps = Int(UsageHistory.week / step)
    var lots: [Forecast.Lot]
    var start: Date
    var sessionSize: Double
    /// The pace multiplier of each step over 2 weeks, and the active hours from `start` to each step:
    /// hours weighted by the multiplier, so hours without use do not count.
    var shape: [Double], active: [Double]

    init(lots: [Forecast.Lot], start: Date, sessionSize: Double, pattern: [Double]?, calendar: Calendar) {
        (self.lots, self.start, self.sessionSize) = (lots, start, sessionSize)
        shape = (0..<2 * Self.steps).map { i in
            pattern.map { $0[UsageHistory.slot(start + Double(i) * Self.step, calendar)] } ?? 1
        }
        active = shape.reduce(into: [0]) { $0.append($0.last! + $1 * Self.step / 3600) }
    }

    /// The pace that uses all the lot's room by its reset, in pp per active hour: highest for much room
    /// close to its reset. Near zero for a lot without a reset.
    func rho(_ lot: Forecast.Lot, step i: Int) -> Double {
        guard let reset = lot.reset else { return lot.room / 1e9 }
        let j = min(active.count - 1, Int((reset.timeIntervalSince(start) / Self.step).rounded(.up)))
        return lot.room / max(0.1, active[j] - active[i])
    }

    func run(pace: Double) -> Forecast.Outcome { serve(pace: pace).outcome }

    /// The most use that the accounts allow before each step: every account used as soon and as much as its
    /// weekly room and session allow. Element i is the total of steps 0..<i.
    func capacity() -> [Double] { serve(pace: nil).served }

    /// Serves `pace` pp per active hour, or with a nil pace all that the accounts allow. Also returns the
    /// total served before each step.
    private func serve(pace: Double?) -> (outcome: Forecast.Outcome, served: [Double]) {
        var lots = self.lots, out = Forecast.Outcome(), total = 0.0, served: [Double] = []
        for i in 0...Self.steps {
            let t = start + Double(i) * Self.step
            for k in lots.indices {
                if let reset = lots[k].reset, t >= reset {
                    out.unused += lots[k].room
                    if lots[k].room > 1 { out.unusedBy = reset }
                    (lots[k].room, lots[k].reset) = (100, reset + UsageHistory.week)
                }
                if let end = lots[k].sessionEnd, t >= end { (lots[k].sessionUsed, lots[k].sessionEnd) = (0, nil) }
            }
            served.append(total)
            guard i < Self.steps else { break }
            var demand = pace.map { $0 * shape[i] * Self.step / 3600 } ?? .infinity
            guard demand > 0 else { continue }
            let rho = lots.map { self.rho($0, step: i) }
            let order = lots.indices.sorted { (rho[$0], -$0) > (rho[$1], -$1) }
            for k in order where demand > 0 {
                let x = min(demand, lots[k].room, sessionSize - lots[k].sessionUsed)
                guard x > 1e-9 else { continue }
                if lots[k].sessionEnd == nil { lots[k].sessionEnd = t + 5 * 3600 }
                lots[k].room -= x
                lots[k].sessionUsed += x
                total += x
                demand -= x
            }
            if pace != nil, demand > 1e-9 {
                out.short += demand
                out.runOut = out.runOut ?? t
            }
        }
        return (out, served)
    }
}
