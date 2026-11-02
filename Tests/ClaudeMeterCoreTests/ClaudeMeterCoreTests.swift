import Foundation
import Testing
@testable import ClaudeMeterCore

private let sampleText = #"You are currently using your subscription to power your Claude Code usage\n\nCurrent session: 0% used\nCurrent week (all models): 100% used · resets Oct 29 at 4pm (America/Los_Angeles)"#

/// Output of a real `claude -p /usage --output-format stream-json --verbose` run.
private let sampleOutput = """
{"type":"system","subtype":"init","session_id":"x","tools":[]}
{"type":"assistant","message":{"content":[{"type":"text","text":"\(sampleText)"}]},"usage_report":{"session":{"total_cost_usd":0,"total_duration_ms":672,"model_usage":{}},"rate_limits":{"limits":[{"kind":"session","group":"session","percent":0,"resets_at":null,"scope":null,"severity":"normal","is_active":false},{"kind":"weekly_all","group":"weekly","percent":100,"resets_at":"2026-10-29T23:00:00.219115+00:00","scope":null,"severity":"critical","is_active":true},{"kind":"weekly_scoped","group":"weekly","percent":12.5,"resets_at":"2026-10-29T23:00:00+00:00","scope":{"model":{"display_name":"Fable"},"surface":null},"severity":"normal","is_active":false}],"extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1230,"utilization":null,"currency":"USD"}}}}
{"type":"result","subtype":"success","result":"done"}
"""

private let reset = Date(timeIntervalSince1970: 1_793_314_800)

private func identity(_ email: String, _ org: String) -> Identity { Identity(email: email, orgId: org) }

private func snapshot(session: Double, sessionReset: Date? = nil, weekly: Double, weeklyReset: Date? = nil) -> UsageSnapshot {
    UsageSnapshot(limits: [UsageLimit(kind: "session", percent: session, resetsAt: sessionReset),
                           UsageLimit(kind: "weekly_all", percent: weekly, resetsAt: weeklyReset)],
                  extraUsage: nil, asOf: reset)
}

@Suite struct ParserTests {
    @Test func parsesRealSample() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let result = UsageParser.parse(sampleOutput, now: now)
        #expect(result.error == nil && !result.rateLimited && !result.signedOut)
        let snap = try #require(result.snapshot)
        #expect(snap.asOf == now)
        #expect(snap.session?.percent == 0 && snap.session?.resetsAt == nil)
        #expect(snap.weekly?.percent == 100 && snap.weekly?.isActive == true)
        #expect(abs(try #require(snap.weekly?.resetsAt).timeIntervalSince(reset) - 0.219115) < 0.000_01)
        #expect(snap.scoped.map(\.model) == ["Fable"])
        #expect(snap.scoped.first?.percent == 12.5 && snap.scoped.first?.resetsAt == reset)
        #expect(snap.extraUsage == ExtraUsage(isEnabled: true, usedCredits: 1230, monthlyLimit: 5000, currency: "USD"))
        #expect(snap.tightestPercent(at: now) == 100)
    }

    @Test func loggedOutOutputIsAnError() {
        let out = """
        {"type":"system","subtype":"init"}
        {"type":"assistant","message":{"content":[{"type":"text","text":"Not logged in · Please run /login"}]}}
        {"type":"result","subtype":"success","result":"Not logged in · Please run /login"}
        """
        let result = UsageParser.parse(out)
        #expect(result.snapshot == nil)
        #expect(result.signedOut)
        #expect(result.error == "Not logged in · Please run /login")
    }

    @Test func otherTextWithoutReportIsAnError() {
        let out = #"{"type":"assistant","usage_report":{"rate_limits":null},"message":{"content":[{"type":"text","text":"/usage is only available for subscription plans."}]}}"#
        let result = UsageParser.parse("garbage\n" + out)
        #expect(result.error == "/usage is only available for subscription plans." && !result.signedOut)
        #expect(UsageParser.parse(#"{"type":"system"}"#).error == "No usage data in Claude Code output")
        #expect(UsageParser.parse("env: node: No such file or directory\n").error == "env: node: No such file or directory")
    }

    @Test func rateLimitTextIsDetected() {
        let out = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Usage endpoint is Rate Limited, try later"}]}}"#
        #expect(UsageParser.parse(out).rateLimited)
        #expect(!UsageParser.parse(sampleOutput.replacingOccurrences(of: "Current session", with: "rate limit")).rateLimited)
    }
}

@Suite struct ClaudeTests {
    @Test func environmentRemovesOverridesAndSetsFolderAndPath() {
        let base = ["PATH": "/somewhere", "HOME": "/Users/u", "LANG": "en_US.UTF-8", "CLAUDECODE": "1",
                    "CLAUDE_CONFIG_DIR": "/Users/u/.claude", "CLAUDE_CODE_OAUTH_TOKEN": "o",
                    "ANTHROPIC_API_KEY": "k", "ANTHROPIC_AUTH_TOKEN": "t"]
        let env = Claude.environment(base: base, configDir: "/Users/u/.claude-accounts/arc",
                                     claude: "/Users/u/.nvm/bin/claude", home: "/Users/u")
        #expect(env == ["HOME": "/Users/u", "LANG": "en_US.UTF-8",
                        "CLAUDE_CONFIG_DIR": "/Users/u/.claude-accounts/arc",
                        "PATH": "/Users/u/.nvm/bin:/Users/u/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"])
    }

    @Test func homeLoginRunsWithoutConfigDir() {
        let env = Claude.environment(base: ["CLAUDE_CONFIG_DIR": "/x"], configDir: "/Users/u/.claude",
                                     claude: "/c/claude", home: "/Users/u")
        #expect(env["CLAUDE_CONFIG_DIR"] == nil)
    }

    @Test func runCapturesOutputWithoutWaitingForGrandchildrenAndTimesOut() async throws {
        let start = Date()
        #expect(try await Claude.runProcess("/bin/sh", ["-c", "printf out; printf err >&2; sleep 5 &"], env: [:], timeout: 5) == "outerr")
        await #expect(throws: ClaudeError.self) { try await Claude.runProcess("/bin/sleep", ["5"], env: [:], timeout: 0.3) }
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func loginScriptQuotesAndUnsets() {
        let script = AccountSetup.loginScript(configDir: "/Users/u/.claude-accounts/o'neil", claude: "/c/claude")
        #expect(script.contains("unset -m 'CLAUDE*'\nunset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN\n"))
        #expect(script.contains(#"export CLAUDE_CONFIG_DIR='/Users/u/.claude-accounts/o'\''neil'"#))
        #expect(script.contains("exec '/c/claude' auth login --claudeai"))
        #expect(AccountSetup.slug("My ARC Team!") == "my-arc-team" && AccountSetup.slug(" ") == "account")
    }
}

@Suite struct CurrentAccountTests {
    let accounts: [Account] = [
        Account(name: "A", configDir: "/f/a", identity: identity("me@x.edu", "org-1")),
        Account(name: "B", configDir: "/f/b", identity: identity("me@x.edu", "org-2")),
        Account(name: "C", configDir: "/f/c", identity: identity("alt@x.edu", "org-1")),
    ]
    var ids: [UUID] { accounts.map(\.id) }

    func current(_ sessions: [(id: UUID, session: LiveSession)], last: UUID? = nil,
                 alive: Set<Int32> = [1, 2, 3, 4]) -> UUID? {
        SessionDetector.current(sessions, accounts: accounts, last: last, probeDir: "/probe", isAlive: alive.contains)
    }

    @Test func readsProfileKeyFromGlobalConfig() throws {
        let json = #"{"numStartups":3,"oauthAccount":{"emailAddress":"Me@X.edu","organizationUuid":"org-1"}}"#
        #expect(try JSONDecoder().decode(GlobalConfig.self, from: Data(json.utf8)).oauthAccount?.key == "me@x.edu|org-1")
        #expect(try JSONDecoder().decode(GlobalConfig.self, from: Data("{}".utf8)).oauthAccount == nil)
    }

    @Test func readsOnlySessionFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, text) in [("41277.json", #"{"pid":41277,"cwd":"/x","updatedAt":1792972814118}"#),
                             ("41277.abc.key", "secret"), ("notes.json", "{}")] {
            try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        #expect(SessionDetector.read(dir: dir.path) == [LiveSession(pid: 41277, cwd: "/x", updatedAt: 1_792_972_814_118)])
    }

    @Test func homeAccountIsMatchedElseProfile() {
        let all = accounts + [Account(name: "No identity", configDir: "/f/d")]
        func home(_ matched: UUID?, _ key: String?) -> UUID? {
            SessionDetector.homeAccount(matched: matched, profileKey: key, in: all)
        }
        #expect(home(ids[0], "me@x.edu|org-2") == ids[0])
        #expect(home(UUID(), "me@x.edu|org-2") == ids[1])
        #expect(home(nil, "x@y.z|o") == nil && home(nil, nil) == nil)
    }

    @Test func latestLiveSessionWinsOutsideProbeDir() {
        let sessions = [
            (ids[0], LiveSession(pid: 1, cwd: "/p", updatedAt: 100)),
            (ids[1], LiveSession(pid: 2, cwd: "/p", updatedAt: 300)),
            (ids[1], LiveSession(pid: 9, cwd: "/p", updatedAt: 900)),
            (ids[2], LiveSession(pid: 3, cwd: "/probe/", updatedAt: 800)),
        ]
        #expect(current(sessions) == ids[1])
        #expect(current(sessions, alive: [1]) == ids[0])
        #expect(current(sessions, last: ids[2], alive: []) == ids[2])
        #expect(current(sessions, last: UUID(), alive: []) == ids[0])
        #expect(SessionDetector.isAlive(getpid()) && !SessionDetector.isAlive(0))
    }
}

@Suite struct SameAccountTests {
    let t = Date(timeIntervalSince1970: 1_800_000_000)
    func snap(_ session: Date?, _ weekly: Date?) -> UsageSnapshot {
        UsageSnapshot(limits: [UsageLimit(kind: "session", percent: 54, resetsAt: session),
                               UsageLimit(kind: "weekly_all", percent: 26, resetsAt: weekly)], asOf: t)
    }

    @Test func matchesOnResetTimes() {
        let home = snap(t, t.addingTimeInterval(86_400))
        #expect(home.sameAccount(as: snap(t.addingTimeInterval(1), t.addingTimeInterval(86_399))))
        #expect(!home.sameAccount(as: snap(t.addingTimeInterval(3_600), t.addingTimeInterval(86_400))))
        #expect(!home.sameAccount(as: snap(nil, t.addingTimeInterval(86_400))))
        #expect(snap(nil, t).sameAccount(as: snap(nil, t)))
        #expect(!snap(nil, nil).sameAccount(as: snap(nil, nil)))
    }
}

@Suite struct OrderTests {
    @Test func currentFirstThenFreeUsageThenNoData() {
        let accounts = (0..<5).map { Account(name: "A\($0)", configDir: "/f/\($0)") }
        let snaps: [UUID: UsageSnapshot] = [
            accounts[0].id: snapshot(session: 90, weekly: 10),
            accounts[1].id: snapshot(session: 20, weekly: 5),
            accounts[2].id: snapshot(session: 0, weekly: 100),
            accounts[3].id: snapshot(session: 20, weekly: 20),
        ]
        let order = accounts.popoverOrder(current: accounts[2].id, now: reset.addingTimeInterval(-60)) { snaps[$0] }
        #expect(order.map(\.name) == ["A2", "A1", "A3", "A0", "A4"])
    }

    @Test func equalPercentSortsByWhenAllTopLimitsReset() {
        let now = reset.addingTimeInterval(-86_400)
        let accounts = (0..<3).map { Account(name: "A\($0)", configDir: "/f/\($0)") }
        let snaps: [UUID: UsageSnapshot] = [
            // Both limits at 100 %: free again only once the later one resets.
            accounts[0].id: snapshot(session: 100, sessionReset: now + 3600, weekly: 100, weeklyReset: now + 80_000),
            accounts[1].id: snapshot(session: 100, sessionReset: now + 7200, weekly: 30, weeklyReset: now + 80_000),
            accounts[2].id: snapshot(session: 100, weekly: 0),
        ]
        let order = accounts.popoverOrder(current: nil, now: now) { snaps[$0] }
        #expect(order.map(\.name) == ["A1", "A0", "A2"])
    }

    @Test func passedResetCountsAsZero() {
        let snap = snapshot(session: 97, sessionReset: reset, weekly: 40, weeklyReset: reset + 86_400)
        #expect(snap.tightestPercent(at: reset - 1) == 97)
        #expect(snap.tightestPercent(at: reset) == 40)
        #expect(snap.tightestResetsAt(at: reset - 1) == reset)
        #expect(snapshot(session: 0, weekly: 0).tightestResetsAt(at: reset) == nil)
    }

    @Test func freshSnapshotNeedsNoErrorAndAtMost30Minutes() {
        var result = ProbeResult(snapshot: snapshot(session: 5, weekly: 1))
        #expect(result.fresh(at: reset + 1800) != nil && result.fresh(at: reset + 1801) == nil)
        result.error = "boom"
        #expect(result.fresh(at: reset) == nil)
    }
}

@Suite struct StateTests {
    @Test func decodesExistingFileShape() throws {
        let json = """
        {"accounts": [{"configDir": "/Users/u/.claude-accounts/arc", "id": "22DC015A-9C30-40EA-83A2-66CB26D30915",
          "identity": {"email": "me@x.edu", "orgId": "o1", "orgName": "ARC", "subscriptionType": "team"},
          "isDefault": false, "name": "ARC", "paused": false}],
         "defaultAccountChecked": true, "lastCurrentAccountID": "22DC015A-9C30-40EA-83A2-66CB26D30915",
         "refreshMinutes": 10,
         "runtime": {"22DC015A-9C30-40EA-83A2-66CB26D30915": {"lastAttempt": "2026-10-26T03:01:57Z", "lastGood": {"asOf": "2026-10-26T03:01:58Z",
           "limits": [{"isActive": true, "kind": "session", "percent": 100, "group": "session", "severity": "critical", "checkedAt": 1}]}}}}
        """
        let state = try JSONDecoder().decode(AppState.self, from: Data(json.utf8))
        let account = try #require(state.accounts.first)
        #expect(account.name == "ARC" && account.configDir == "/Users/u/.claude-accounts/arc")
        #expect(account.identity == Identity(email: "me@x.edu", orgId: "o1", orgName: "ARC", subscriptionType: "team"))
        #expect(account.identity?.plan == "Team")
        #expect(state.lastCurrentAccountID == account.id)
    }

    @Test func roundTripsAndRenamesUndecodableFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        var state = AppState()
        state.accounts = [Account(name: "ARC", configDir: "/a")]
        try state.save(to: url)
        #expect(AppState.load(from: url) == state)
        try #"{"accounts": [{"id": "#.write(to: url, atomically: true, encoding: .utf8)
        #expect(AppState.load(from: url) == AppState())
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: url.path + ".bad"))
    }
}

private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

private func weeklySnapshot(_ weekly: Double, reset: Date?, asOf: Date, session: Double = 0,
                            sessionReset: Date? = nil) -> UsageSnapshot {
    UsageSnapshot(limits: [UsageLimit(kind: "session", percent: session, resetsAt: sessionReset),
                           UsageLimit(kind: "weekly_all", percent: weekly, resetsAt: reset)], asOf: asOf)
}

@Suite struct HistoryTests {
    let t0 = at(1_793_000_000), reset = at(1_793_300_000)

    func total(_ h: UsageHistory) -> Double { h.hourly.values.reduce(0, +) }

    @Test func booksOnlyTheIncreaseInOneWindow() {
        var h = UsageHistory()
        h.add(weeklySnapshot(50, reset: reset, asOf: t0), key: "a")
        #expect(total(h) == 0)
        h.add(weeklySnapshot(53, reset: reset, asOf: t0 + 5400), key: "a")
        #expect(abs(total(h) - 3) < 1e-9 && h.hourly.count == 3)
    }

    @Test func ignoresOlderCopiesAndDips() {
        var h = UsageHistory()
        h.add(weeklySnapshot(52, reset: reset, asOf: t0), key: "a")
        h.add(weeklySnapshot(47, reset: reset, asOf: t0 - 60), key: "a")
        h.add(weeklySnapshot(51, reset: reset, asOf: t0 + 60), key: "a")
        h.add(weeklySnapshot(53, reset: reset, asOf: t0 + 120), key: "a")
        #expect(abs(total(h) - 1) < 1e-9)
    }

    @Test func aPassedResetBooksTheNewWindowAndMarksAGap() {
        var h = UsageHistory()
        h.add(weeklySnapshot(80, reset: reset, asOf: reset - 180), key: "a")
        h.add(weeklySnapshot(1, reset: reset + UsageHistory.week, asOf: reset + 120), key: "a")
        #expect(abs(total(h) - 1) < 1e-9 && h.gapAt == nil)
        h.add(weeklySnapshot(9, reset: reset + UsageHistory.week, asOf: reset + 20 * 3600), key: "b")
        h.add(weeklySnapshot(4, reset: reset + 2 * UsageHistory.week, asOf: reset + UsageHistory.week + 3600), key: "b")
        #expect(h.gapAt == reset + UsageHistory.week + 3600)
        #expect(h.paceIsLowerBound(at: reset + UsageHistory.week + 7200))
    }

    @Test func aResetThatMovesBeforeItPassesBooksNothing() {
        var h = UsageHistory()
        h.add(weeklySnapshot(30, reset: reset, asOf: t0), key: "a")
        h.add(weeklySnapshot(40, reset: reset + 3600, asOf: t0 + 60), key: "a")
        #expect(total(h) == 0)
    }

    @Test func paceNeedsSevenDays() {
        var h = UsageHistory()
        for hour in 0...(8 * 24) {
            h.add(weeklySnapshot(Double(hour % 100), reset: reset + Double(hour / 100) * 3600, asOf: t0 + Double(hour) * 3600), key: "a")
        }
        #expect(h.pace(at: t0 + 6 * 86400) == nil)
        let pace = h.pace(at: t0 + 8 * 86400)
        #expect(pace.map { abs($0 - 1) < 0.02 } == true)
    }

    @Test func anAccountFirstSeenMidWeekMarksAGap() {
        var h = UsageHistory()
        h.add(weeklySnapshot(10, reset: reset, asOf: t0), key: "a")
        h.add(weeklySnapshot(0, reset: t0 + 6 * 86400, asOf: t0 + 3600), key: "b")
        #expect(h.gapAt == nil)
        h.add(weeklySnapshot(40, reset: t0 + 5 * 86400, asOf: t0 + 3 * 86400), key: "c")
        #expect(h.gapAt == t0 + 3 * 86400)
    }

    @Test func learnsSessionSizeFromOneSessionWindow() {
        var h = UsageHistory()
        #expect(h.sessionSize == 17)
        let end = t0 + 4 * 3600
        h.add(weeklySnapshot(2, reset: reset, asOf: t0, session: 8, sessionReset: end), key: "a")
        h.add(weeklySnapshot(17, reset: reset, asOf: t0 + 3600, session: 100, sessionReset: end), key: "a")
        #expect(abs(h.sessionSize - 49 / 2.92) < 1e-9)
    }

    @Test func patternHasMeanOneAfterAWeek() throws {
        var h = UsageHistory()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        #expect(h.pattern(at: t0, calendar: calendar) == nil)
        for hour in 0...(10 * 24) {
            let t = t0 + Double(hour) * 3600
            let busy = calendar.component(.hour, from: t) >= 18
            h.add(weeklySnapshot(Double(hour) * (busy ? 2 : 1) / 10, reset: reset, asOf: t), key: "a")
        }
        let pattern = try #require(h.pattern(at: t0 + 10 * 86400, calendar: calendar))
        #expect(abs(pattern.reduce(0, +) / 168 - 1) < 1e-9)
        #expect(pattern[20] > pattern[10])
    }
}

/// The 8 accounts at 2026-11-02 03:26 UTC: weekly %, weekly reset, session %, session reset, snapshot time.
/// Expected numbers come from the Python prototype (flat pattern, session size 17).
private let fixture: [(String, Double, Double, Double, Double?, Double)] = [
    ("alpha", 65, 1793840399.56941, 0, nil, 1793589957.656),
    ("bravo", 65, 1794121200.385537, 98, 1793591400.385513, 1793589956.495),
    ("charlie", 17, 1794171599.932127, 100, 1793596199.932103, 1793589962.042),
    ("delta", 65, 1793919599.892516, 0, nil, 1793589958.972),
    ("echo", 56, 1793905200.241633, 3, 1793606400.241614, 1793589064.318),
    ("foxtrot", 63, 1794006000.035022, 2, 1793606400.035005, 1793589955.195),
    ("golf", 93, 1793844000.131441, 0, nil, 1793589963.239),
    ("hotel", 17, 1794175200.294837, 0, nil, 1793589960.657),
]
private let fixtureNow = at(1793589963.239)

private func fixtureData() -> (accounts: [Account], results: [UUID: ProbeResult]) {
    let accounts = fixture.map { Account(name: $0.0, configDir: "", identity: identity($0.0, "org")) }
    var results: [UUID: ProbeResult] = [:]
    for (account, f) in zip(accounts, fixture) {
        results[account.id] = ProbeResult(snapshot: weeklySnapshot(f.1, reset: at(f.2), asOf: at(f.5), session: f.3,
                                                                   sessionReset: f.4.map(at)))
    }
    return (accounts, results)
}

@Suite struct ForecastTests {
    func make(current: String? = nil, history: UsageHistory = UsageHistory()) -> (Forecast, [Account]) {
        let (accounts, results) = fixtureData()
        let id = accounts.first { $0.name == current }?.id
        return (Forecast.make(accounts: accounts, results: results, history: history, current: id, now: fixtureNow), accounts)
    }

    @Test func matchesThePrototypeOnTheRealSnapshot() throws {
        let (f, _) = make()
        #expect(f.accounts == 8 && f.left == 359)
        let pace = try #require(f.pace)
        #expect(f.paceIsLowerBound && abs(pace - 4.480143) < 1e-5)
        #expect(abs(f.steadyLeft - 539.598970) < 1e-5)
        let o = try #require(f.outcome)
        #expect(o.short == 0 && o.unused == 0 && !o.runsOut)
        #expect(!f.alert)
    }

    @Test func runOutAtAHigherPaceMatchesThePrototype() throws {
        let (accounts, results) = fixtureData()
        let simulation = Simulation(lots: Self.lots(accounts, results), start: fixtureNow, sessionSize: 17, pattern: nil,
                                    calendar: .current)
        let o = simulation.run(pace: 6)
        #expect(abs(o.short - 60) < 1e-6 && o.unused == 0)
        #expect(o.runOut == fixtureNow + 2 * 86400 + 11 * 3600 + 50 * 60)
    }

    @Test func weeklyOnlyRunOutPaceMatchesTheClosedForm() {
        let (accounts, results) = fixtureData()
        let simulation = Simulation(lots: Self.lots(accounts, results), start: fixtureNow, sessionSize: 1e9, pattern: nil,
                                    calendar: .current)
        var (low, high) = (0.0, 30.0)
        for _ in 0..<30 {
            let mid = (low + high) / 2
            if simulation.run(pace: mid).short > 0.01 { high = mid } else { low = mid }
        }
        let simulated = high
        // Least over the resets of (room now + refills so far) / hours to that reset.
        let lots = fixture.map { (reset: at($0.2), room: 100 - $0.1) }.sorted { $0.reset < $1.reset }
        let room = lots.reduce(0) { $0 + $1.room }
        let ends = lots.map(\.reset) + [fixtureNow + UsageHistory.week]
        let exact = ends.enumerated().map { m, end in (room + 100 * Double(m)) / (end.timeIntervalSince(fixtureNow) / 3600) }.min()!
        #expect(abs(simulated - 5.153254) < 1e-3 && abs(simulated / exact - 1) < 0.002)
    }

    @Test func theRefillOnTheRealSnapshotIsTheFirstReset() throws {
        let refill = try #require(make().0.refill)
        #expect(refill.date == at(1793840399.56941) && refill.refills == 0)
        #expect(abs(refill.room - 359) < 1e-9)
        #expect(abs(refill.perDay - 359 / (refill.date.timeIntervalSince(fixtureNow) / 86400)) < 1e-9)
    }

    @Test func aResetThatRefillsLittleDoesNotHideTheNextOne() throws {
        let a = Account(name: "a", configDir: ""), b = Account(name: "b", configDir: ""), c = Account(name: "c", configDir: "")
        var results = [a.id: ProbeResult(snapshot: weeklySnapshot(20, reset: fixtureNow + 2 * 3600, asOf: fixtureNow)),
                       b.id: ProbeResult(snapshot: weeklySnapshot(90, reset: fixtureNow + 100 * 3600, asOf: fixtureNow))]
        let refill = try #require(Forecast.make(accounts: [a, b], results: results, history: UsageHistory(),
                                                current: nil, now: fixtureNow).refill)
        // a gives one session (17 pp) before its reset and 100 pp after it; b gives its 10 pp.
        #expect(refill.date == fixtureNow + 100 * 3600 && abs(refill.room - 127) < 1e-9 && refill.refills == 1)
        #expect(abs(refill.perDay - 127 / (100.0 / 24)) < 1e-9)
        results[c.id] = ProbeResult(snapshot: weeklySnapshot(50, reset: nil, asOf: fixtureNow))
        #expect(Forecast.make(accounts: [c], results: results, history: UsageHistory(), current: nil, now: fixtureNow).refill == nil)
    }

    @Test func nextIsTheUsableAccountWithTheMostRoomPerHour() {
        func next(current: String) -> String? {
            let (f, accounts) = make(current: current)
            return accounts.first { $0.id == f.next }?.name
        }
        #expect(next(current: "hotel") == nil)
        #expect(next(current: "golf") == "hotel")
        #expect(next(current: "charlie") == "hotel")
    }

    @Test func oneLoginInTwoFoldersIsOneAccount() {
        var (accounts, results) = fixtureData()
        let copy = Account(name: "copy", configDir: "", identity: accounts[0].identity)
        accounts.append(copy)
        results[copy.id] = results[accounts[0].id]
        let f = Forecast.make(accounts: accounts, results: results, history: UsageHistory(), current: nil, now: fixtureNow)
        #expect(f.accounts == 8 && f.left == 359)
    }

    @Test func aPassedResetRefillsAndExpiresAWeekLater() {
        let (accounts, results) = fixtureData()
        let reset = at(1793840399.56941)
        let later = Forecast.make(accounts: accounts, results: results, history: UsageHistory(), current: nil, now: reset + 60)
        #expect(later.left == 359 - 35 + 100)
        #expect(later.lastReset == reset + UsageHistory.week)
    }

    @Test func noForecastUntilEveryAccountHasNumbers() {
        var (accounts, results) = fixtureData()
        results[accounts[3].id] = nil
        #expect(Forecast.make(accounts: accounts, results: results, history: UsageHistory(), current: nil, now: fixtureNow).accounts == 0)
        results[accounts[3].id] = ProbeResult(error: "Not signed in", signedOut: true)
        #expect(Forecast.make(accounts: accounts, results: results, history: UsageHistory(), current: nil, now: fixtureNow).accounts == 7)
        accounts.append(Account(name: "new", configDir: ""))
        results[accounts[8].id] = ProbeResult(error: "Timed out waiting for claude")
        #expect(Forecast.make(accounts: accounts, results: results, history: UsageHistory(), current: nil, now: fixtureNow).accounts == 0)
    }

    @Test func aResetAtTheEndOfTheWeekCounts() {
        let lot = Forecast.Lot(ids: [UUID()], asOf: fixtureNow, used: 50, room: 50, reset: fixtureNow + UsageHistory.week - 60)
        let simulation = Simulation(lots: [lot], start: fixtureNow, sessionSize: 17, pattern: nil, calendar: .current)
        #expect(simulation.run(pace: 0).unused == 50)
    }

    @Test func theAccountInUseKeepsItsPlaceAfterAFailedProbe() {
        let (accounts, results) = fixtureData()
        let current = accounts.first { $0.name == "alpha" }!
        var failed = results
        failed[current.id]?.error = "Rate limited"
        let f = Forecast.make(accounts: accounts, results: failed, history: UsageHistory(), current: current.id, now: fixtureNow)
        #expect(f.next == nil)
    }

    @Test func theOtherFolderOfTheAccountInUseIsNeverNext() {
        var (accounts, results) = fixtureData()
        let best = accounts.first { $0.name == "hotel" }!
        let twin = Account(name: "twin", configDir: "", identity: best.identity)
        accounts.append(twin)
        results[twin.id] = ProbeResult(snapshot: results[best.id]?.snapshot.map { var s = $0; s.asOf -= 60; return s })
        let f = Forecast.make(accounts: accounts, results: results, history: UsageHistory(), current: twin.id, now: fixtureNow)
        #expect(f.next == nil)
    }

    @Test func alertsWhenNoAccountIsUsable() {
        let (accounts, _) = fixtureData()
        var results: [UUID: ProbeResult] = [:]
        for account in accounts {
            results[account.id] = ProbeResult(snapshot: weeklySnapshot(100, reset: fixtureNow + 86400, asOf: fixtureNow))
        }
        let f = Forecast.make(accounts: accounts, results: results, history: UsageHistory(), current: nil, now: fixtureNow)
        #expect(f.alert && f.next == nil && f.left == 0)
    }

    static func lots(_ accounts: [Account], _ results: [UUID: ProbeResult]) -> [Forecast.Lot] {
        zip(accounts, fixture).map { account, f in
            var lot = Forecast.Lot(ids: [account.id], asOf: at(f.5), used: f.1, room: 100 - f.1, reset: at(f.2))
            if let end = f.4.map(at), end > fixtureNow { (lot.sessionUsed, lot.sessionEnd) = (17 * f.3 / 100, end) }
            return lot
        }
    }
}
