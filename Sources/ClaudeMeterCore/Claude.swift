import Foundation
import os

public enum Paths {
    public static let home = NSHomeDirectory()
    public static let support = URL(fileURLWithPath: home + "/Library/Application Support/ClaudeMeter")
    public static let stateFile = support.appendingPathComponent("state.json")
    /// Working directory of every child `claude` process.
    public static let probeDir = support.appendingPathComponent("probe")
    public static let accountsRoot = home + "/.claude-accounts"
}

public struct ClaudeError: LocalizedError {
    public var errorDescription: String?
    public init(_ message: String) { errorDescription = message }
    public static let notFound = ClaudeError("Claude Code not found")
}

/// Runs the official `claude` CLI for one account. The CLI does all authentication: this code
/// never reads credentials, refreshes tokens or calls Anthropic endpoints.
public struct Claude: Sendable {
    public let path: String

    static func installDirectories(home: String) -> [String] {
        [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    }

    /// Apps opened from Finder get a minimal PATH, so the login shell is asked once per launch.
    private static let loginShellLookup = Task {
        let output = try? await runProcess("/bin/zsh", ["-lc", "command -v claude"], env: nil, timeout: 30)
        return output?.split(whereSeparator: \.isNewline).last.map(String.init)
    }

    /// The first executable `claude` in the known install locations, else the login shell's.
    public static func locate() async -> Claude? {
        let fm = FileManager.default
        var path = installDirectories(home: Paths.home).map { $0 + "/claude" }.first(where: fm.isExecutableFile)
        if path == nil { path = await loginShellLookup.value }
        guard let path, path.hasPrefix("/"), fm.isExecutableFile(atPath: path) else { return nil }
        return Claude(path: path)
    }

    /// Every CLAUDE* variable and the API token variables removed, CLAUDE_CONFIG_DIR set to the folder
    /// (unset for ~/.claude, the CLI default), and PATH led by the folder of `claude`, so a
    /// `#!/usr/bin/env node` script finds node.
    static func environment(base: [String: String], configDir: String, claude: String,
                            home: String) -> [String: String] {
        let removed: Set = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"]
        var env = base.filter { !$0.key.hasPrefix("CLAUDE") && !removed.contains($0.key) }
        if configDir != home + "/.claude" { env["CLAUDE_CONFIG_DIR"] = configDir }
        let claudeDir = (claude as NSString).deletingLastPathComponent
        env["PATH"] = ([claudeDir] + installDirectories(home: home) + ["/usr/bin", "/bin"]).joined(separator: ":")
        return env
    }

    /// Runs `claude -p /usage`. The snapshot's `asOf` is the time Claude Code fetched the numbers.
    public func usage(_ account: Account) async -> ProbeResult {
        let arguments = ["-p", "/usage", "--output-format", "stream-json", "--verbose",
                         "--no-session-persistence", "--strict-mcp-config"]
        do {
            let now = Date()
            var result = UsageParser.parse(try await runClaude(arguments, account), now: now)
            if let fetched = GlobalConfig.read(account.globalConfigPath)?.usageFetchedAt {
                result.snapshot?.asOf = min(fetched, now)
            }
            return result
        } catch {
            return ProbeResult(error: error.localizedDescription)
        }
    }

    /// Runs `claude auth status`, which prints JSON without secrets. Nil when signed out.
    public func identity(_ account: Account) async throws -> Identity? {
        struct Status: Decodable { var loggedIn: Bool }
        let output = try await runClaude(["auth", "status"], account)
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}") else {
            throw ClaudeError("Unexpected output from claude auth status")
        }
        let data = Data(output[start...end].utf8)
        guard try JSONDecoder().decode(Status.self, from: data).loggedIn else { return nil }
        return try JSONDecoder().decode(Identity.self, from: data)
    }

    private func runClaude(_ arguments: [String], _ account: Account) async throws -> String {
        let env = Self.environment(base: ProcessInfo.processInfo.environment, configDir: account.configDir,
                                   claude: path, home: Paths.home)
        return try await Self.runProcess(path, arguments, env: env, timeout: 30)
    }

    /// Runs a process in the probe directory and returns its stdout and stderr, written to a temporary
    /// file so no pipe can block. On timeout the child gets SIGTERM, then SIGKILL 2 s later.
    static func runProcess(_ executable: String, _ arguments: [String], env: [String: String]?,
                           timeout: TimeInterval) async throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: Paths.probeDir, withIntermediateDirectories: true)
        let outURL = fm.temporaryDirectory.appendingPathComponent("claudemeter-\(UUID().uuidString).log")
        fm.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? fm.removeItem(at: outURL) }
        let out = try FileHandle(forWritingTo: outURL)
        defer { try? out.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let env { process.environment = env }
        process.currentDirectoryURL = Paths.probeDir
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = out
        let exited = OSAllocatedUnfairLock(initialState: false)
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in
                exited.withLock { $0 = true }
                continuation.resume()
            }
            do { try process.run() } catch {
                continuation.resume(throwing: error)
                return
            }
            let pid = process.processIdentifier
            for (delay, signal) in [(timeout, SIGTERM), (timeout + 2, SIGKILL)] {
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    guard !exited.withLock({ $0 }) else { return }
                    timedOut.withLock { $0 = true }
                    kill(pid, signal)
                }
            }
        }
        if timedOut.withLock({ $0 }) { throw ClaudeError("Timed out waiting for claude") }
        return String(decoding: try Data(contentsOf: outURL), as: UTF8.self)
    }
}

/// Creates account folders and the Terminal script that signs one in.
public enum AccountSetup {
    /// "My ARC Team" -> "my-arc-team", at most 40 characters.
    static func slug(_ name: String) -> String {
        let words = name.lowercased().split { !($0.isLetter || $0.isNumber) }
        return words.isEmpty ? "account" : String(words.joined(separator: "-").prefix(40))
    }

    /// Creates `<root>/<slug>` with mode 0700, adding a number when taken. Returns its path.
    public static func createFolder(name: String, root: String = Paths.accountsRoot) throws -> String {
        let fm = FileManager.default
        let privateMode: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true, attributes: privateMode)
        var path = root + "/" + slug(name)
        var n = 1
        while fm.fileExists(atPath: path) {
            n += 1
            path = root + "/" + slug(name) + "-\(n)"
        }
        try fm.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: privateMode)
        return path
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// A zsh script that runs `claude auth login` with the environment rules of `Claude.environment`.
    static func loginScript(configDir: String, claude: String) -> String {
        """
        #!/bin/zsh
        unset -m 'CLAUDE*'
        unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
        export CLAUDE_CONFIG_DIR=\(quote(configDir))
        exec \(quote(claude)) auth login --claudeai

        """
    }

    /// Writes `login-<account id>.command`; opening it runs the sign-in in Terminal.
    public static func writeLoginScript(for account: Account, claude: String) throws -> URL {
        try FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        let url = Paths.support.appendingPathComponent("login-\(account.id.uuidString).command")
        let script = loginScript(configDir: account.configDir, claude: claude)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    /// Deletes every login script. No sign-in is in progress at launch.
    public static func removeLoginScripts() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Paths.support, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.lastPathComponent.hasPrefix("login-") && url.pathExtension == "command" {
            try? fm.removeItem(at: url)
        }
    }
}
