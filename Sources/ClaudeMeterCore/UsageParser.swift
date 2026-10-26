import Foundation

/// Parses the JSON lines printed by `claude -p /usage --output-format stream-json --verbose`.
/// Lines that are not JSON, and unknown keys, are ignored.
public enum UsageParser {
    private struct Line: Decodable {
        struct Message: Decodable { var content: [Content]? }
        struct Content: Decodable { var type: String?, text: String? }
        struct Report: Decodable { var rateLimits: RateLimits? }
        struct RateLimits: Decodable { var limits: [Limit], extraUsage: ExtraUsage? }
        struct Limit: Decodable {
            var kind: String, percent: Double, resetsAt: String?, isActive: Bool?, scope: Scope?
        }
        struct Scope: Decodable { var model: Model? }
        struct Model: Decodable { var displayName: String? }
        var type: String?, message: Message?, usageReport: Report?, result: String?
    }

    /// The assistant line's usage_report, or an error that carries the printed text.
    public static func parse(_ output: String, now: Date = Date()) -> ProbeResult {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let lines = output.split(whereSeparator: \.isNewline)
            .compactMap { try? decoder.decode(Line.self, from: Data($0.utf8)) }
        let assistant = lines.filter { $0.type == "assistant" }
        let text = assistant.flatMap { $0.message?.content ?? [] }
            .compactMap { $0.type == "text" ? $0.text : nil }.joined(separator: "\n")
        let resultText = lines.last { $0.type == "result" }?.result ?? ""
        var result = ProbeResult()
        if let report = assistant.compactMap(\.usageReport?.rateLimits).last {
            let limits = report.limits.map {
                UsageLimit(kind: $0.kind, percent: $0.percent, resetsAt: $0.resetsAt.flatMap(parseDate),
                           model: $0.scope?.model?.displayName, isActive: $0.isActive ?? false)
            }
            result.snapshot = UsageSnapshot(limits: limits, extraUsage: report.extraUsage, asOf: now)
        } else {
            // Raw output only when no line is JSON, e.g. "env: node: No such file or directory".
            let message = [text, resultText, lines.isEmpty ? output : ""]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "No usage data in Claude Code output"
            let lower = message.lowercased()
            result.signedOut = lower.contains("not logged in") || lower.contains("/login")
            result.rateLimited = lower.contains("rate limit")
            result.error = message
        }
        return result
    }

    /// ISO 8601 with or without fractional seconds.
    static func parseDate(_ s: String) -> Date? {
        (try? Date(s, strategy: .iso8601))
            ?? (try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }
}

/// The parts of a Claude Code global config file (`.claude.json`) the app reads.
struct GlobalConfig: Decodable {
    struct OAuthAccount: Decodable { var emailAddress: String?, organizationUuid: String? }
    struct UsageCache: Decodable { var fetchedAtMs: Double? }
    var oauthAccount: OAuthAccount?
    var cachedUsageUtilization: UsageCache?

    static func read(_ path: String) -> GlobalConfig? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(GlobalConfig.self, from: data)
    }

    /// Identity key (see `Identity.key`) of the folder's current login. `/login` rewrites it.
    var signedInKey: String? {
        Identity(email: oauthAccount?.emailAddress, orgId: oauthAccount?.organizationUuid).key
    }

    /// When Claude Code last fetched the usage numbers it serves.
    var usageFetchedAt: Date? {
        cachedUsageUtilization?.fetchedAtMs.map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}
