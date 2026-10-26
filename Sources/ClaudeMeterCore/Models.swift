import Foundation

/// Who an account folder is signed in as, from `claude auth status`. Holds no secrets.
public struct Identity: Codable, Sendable, Equatable {
    public var email, orgId, orgName, subscriptionType: String?

    public init(email: String? = nil, orgId: String? = nil, orgName: String? = nil, subscriptionType: String? = nil) {
        (self.email, self.orgId, self.orgName, self.subscriptionType) = (email, orgId, orgName, subscriptionType)
    }

    /// Accounts are distinct per email and organization.
    public var key: String? {
        guard let email, !email.isEmpty else { return nil }
        return email.lowercased() + "|" + (orgId ?? "")
    }

    /// "team" -> "Team".
    public var plan: String? { subscriptionType.map { $0.prefix(1).uppercased() + $0.dropFirst() } }
}

/// One Claude Code config folder. `configDir` is passed verbatim as CLAUDE_CONFIG_DIR (except for
/// ~/.claude), because Claude Code keys its Keychain item on that exact string.
public struct Account: Codable, Sendable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    public var configDir: String
    public var identity: Identity?

    public init(name: String, configDir: String, identity: Identity? = nil) {
        self.name = name
        self.configDir = configDir
        self.identity = identity
    }

    /// The plain `claude` login in ~/.claude, switched with `claude auth login`. Not a tracked account:
    /// its usage is matched to one by reset times. Its children run with CLAUDE_CONFIG_DIR unset.
    public static let home = Account(name: "~/.claude", configDir: Paths.home + "/.claude")

    /// Claude Code's global config file: inside the folder, or ~/.claude.json for ~/.claude.
    public var globalConfigPath: String {
        (configDir == Account.home.configDir ? Paths.home : configDir) + "/.claude.json"
    }
}

/// One rate limit: kind (session, weekly_all or weekly_scoped), percent used and reset time.
public struct UsageLimit: Codable, Sendable, Equatable {
    public var kind: String
    public var percent: Double
    public var resetsAt: Date?
    /// Model a weekly_scoped limit applies to, e.g. "Fable".
    public var model: String?
    public var isActive = false

    public init(kind: String, percent: Double, resetsAt: Date? = nil, model: String? = nil, isActive: Bool = false) {
        (self.kind, self.percent, self.resetsAt, self.model, self.isActive) = (kind, percent, resetsAt, model, isActive)
    }

    /// Percent used at `now`: 0 once the reset time has passed.
    public func percent(at now: Date) -> Double {
        if let resetsAt, resetsAt <= now { return 0 }
        return percent
    }
}

/// Pay-as-you-go usage beyond the plan. Amounts are in cents.
public struct ExtraUsage: Codable, Sendable, Equatable {
    public var isEnabled: Bool
    public var usedCredits, monthlyLimit: Double?
    public var currency: String?
}

/// All limits of one account at one time.
public struct UsageSnapshot: Codable, Sendable, Equatable {
    public var limits: [UsageLimit]
    public var extraUsage: ExtraUsage?
    /// When Anthropic produced the numbers. Claude Code can serve a cached copy.
    public var asOf: Date

    public init(limits: [UsageLimit], extraUsage: ExtraUsage? = nil, asOf: Date) {
        (self.limits, self.extraUsage, self.asOf) = (limits, extraUsage, asOf)
    }

    public var session: UsageLimit? { limits.first { $0.kind == "session" } }
    public var weekly: UsageLimit? { limits.first { $0.kind == "weekly_all" } }
    /// Per-model weekly limits worth showing: in use or active.
    public var scoped: [UsageLimit] {
        limits.filter { $0.kind == "weekly_scoped" && ($0.percent > 0 || $0.isActive) }
    }

    /// The limit closest to running out: max of session and weekly_all at `now`.
    public func tightestPercent(at now: Date) -> Double? {
        [session, weekly].compactMap { $0?.percent(at: now) }.max()
    }

    /// True when both snapshots likely come from one account: their session and weekly limits reset
    /// at the same times (within 2 min, or both unset).
    public func sameAccount(as other: UsageSnapshot) -> Bool {
        func close(_ a: Date?, _ b: Date?) -> Bool {
            guard let a, let b else { return a == nil && b == nil }
            return abs(a.timeIntervalSince(b)) < 120
        }
        guard session?.resetsAt != nil || weekly?.resetsAt != nil else { return false }
        return close(session?.resetsAt, other.session?.resetsAt) && close(weekly?.resetsAt, other.weekly?.resetsAt)
    }

    /// When every limit at the tightest percent has reset. Nil when unknown or at 0 %.
    public func tightestResetsAt(at now: Date) -> Date? {
        guard let top = tightestPercent(at: now), top > 0 else { return nil }
        return [session, weekly].compactMap { $0 }.filter { $0.percent(at: now) == top }
            .compactMap(\.resetsAt).max()
    }
}

/// Parsed outcome of one `claude -p /usage` run, or a failed `claude` run.
public struct ProbeResult: Encodable, Sendable {
    public var snapshot: UsageSnapshot?
    public var error: String?
    public var signedOut = false
    /// The output said Claude Code's usage endpoint is rate limited.
    public var rateLimited = false

    public init(snapshot: UsageSnapshot? = nil, error: String? = nil, signedOut: Bool = false) {
        (self.snapshot, self.error, self.signedOut) = (snapshot, error, signedOut)
    }

    /// The snapshot for the menu bar and the sort order: nil after an error or when older than 30 min.
    public func fresh(at now: Date) -> UsageSnapshot? {
        guard error == nil, let snapshot, now.timeIntervalSince(snapshot.asOf) <= 30 * 60 else { return nil }
        return snapshot
    }
}

extension [Account] {
    /// Popover order: the account in use; then accounts with numbers, lowest tightest percent first and,
    /// at equal percent, the one whose tightest limits reset first; then the rest; ties in user order.
    public func popoverOrder(current: UUID?, now: Date, snapshot: (UUID) -> UsageSnapshot?) -> [Account] {
        func key(_ a: Account, _ index: Int) -> (group: Int, percent: Double, resetsAt: Double, index: Int) {
            if a.id == current { return (0, 0, 0, index) }
            guard let s = snapshot(a.id), let p = s.tightestPercent(at: now) else { return (2, 0, 0, index) }
            return (1, p, s.tightestResetsAt(at: now)?.timeIntervalSince1970 ?? .infinity, index)
        }
        return enumerated().map { (account: $0.element, key: key($0.element, $0.offset)) }
            .sorted { $0.key < $1.key }.map(\.account)
    }
}

/// Everything the app remembers, stored in state.json. Holds no secrets; unknown keys are ignored.
public struct AppState: Codable, Sendable, Equatable {
    /// Accounts in the user's order.
    public var accounts: [Account] = []
    public var lastCurrentAccountID: UUID?

    public init() {}

    /// Empty when the file is missing. A file that fails to decode is renamed to state.json.bad.
    public static func load(from url: URL = Paths.stateFile) -> AppState {
        guard let data = try? Data(contentsOf: url) else { return AppState() }
        if let state = try? JSONDecoder().decode(AppState.self, from: data) { return state }
        let bad = url.appendingPathExtension("bad")
        try? FileManager.default.removeItem(at: bad)
        try? FileManager.default.moveItem(at: url, to: bad)
        return AppState()
    }

    public func save(to url: URL = Paths.stateFile) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
