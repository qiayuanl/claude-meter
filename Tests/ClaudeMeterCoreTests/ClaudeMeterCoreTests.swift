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

    func current(_ folders: [FolderSessions], last: UUID? = nil, alive: Set<Int32> = [1, 2, 3, 4]) -> UUID? {
        SessionDetector.current(folders: folders, accounts: accounts, last: last, probeDir: "/probe",
                                isAlive: alive.contains)
    }

    @Test func readsSignedInKeyFromGlobalConfig() throws {
        let json = #"{"numStartups":3,"oauthAccount":{"emailAddress":"Me@X.edu","organizationUuid":"org-1"}}"#
        #expect(try JSONDecoder().decode(GlobalConfig.self, from: Data(json.utf8)).signedInKey == "me@x.edu|org-1")
        #expect(try JSONDecoder().decode(GlobalConfig.self, from: Data("{}".utf8)).signedInKey == nil)
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

    @Test func folderSessionsFollowItsCurrentLogin() {
        let session = [LiveSession(pid: 1, cwd: "/p", updatedAt: 1)]
        // ~/.claude signed in as B's identity counts for B; an unknown login there is dropped.
        #expect(current([FolderSessions(accountID: nil, signedInKey: "me@x.edu|org-2", sessions: session)]) == ids[1])
        #expect(current([FolderSessions(accountID: nil, signedInKey: "x@y.z|o", sessions: session)], last: ids[2]) == ids[2])
        // A's folder switched to C's login with /login; without a known login it stays A's.
        #expect(current([FolderSessions(accountID: ids[0], signedInKey: "alt@x.edu|org-1", sessions: session)]) == ids[2])
        #expect(current([FolderSessions(accountID: ids[1], signedInKey: nil, sessions: session)]) == ids[1])
    }

    @Test func latestLiveSessionWinsOutsideProbeDir() {
        let folders = [
            FolderSessions(accountID: ids[0], signedInKey: nil, sessions: [LiveSession(pid: 1, cwd: "/p", updatedAt: 100)]),
            FolderSessions(accountID: ids[1], signedInKey: nil, sessions: [LiveSession(pid: 2, cwd: "/p", updatedAt: 300),
                                                                          LiveSession(pid: 9, cwd: "/p", updatedAt: 900)]),
            FolderSessions(accountID: ids[2], signedInKey: nil, sessions: [LiveSession(pid: 3, cwd: "/probe/", updatedAt: 800)]),
        ]
        #expect(current(folders) == ids[1])
        #expect(current(folders, alive: [1]) == ids[0])
        #expect(current(folders, last: ids[2], alive: []) == ids[2])
        #expect(current(folders, last: UUID(), alive: []) == ids[0])
        #expect(SessionDetector.isAlive(getpid()) && !SessionDetector.isAlive(0))
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
        var result = ProbeResult()
        result.snapshot = snapshot(session: 5, weekly: 1)
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
