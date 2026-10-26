import Foundation

/// A Claude Code session, from `<folder>/sessions/<pid>.json`.
public struct LiveSession: Sendable, Equatable {
    var pid: Int32
    var cwd: String?
    /// Milliseconds since 1970.
    var updatedAt: Double
}

/// Finds the account the user works in: the one whose live session was updated last.
public enum SessionDetector {
    /// Reads every `<pid>.json` file in `dir`. Other files (such as `<pid>.<hash>.key`) are never opened.
    static func read(dir: String) -> [LiveSession] {
        struct File: Decodable { var cwd: String?, updatedAt: Double?, startedAt: Double? }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.compactMap { name in
            guard name.hasSuffix(".json"), let pid = Int32(name.dropLast(5)),
                  let data = FileManager.default.contents(atPath: dir + "/" + name),
                  let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
            return LiveSession(pid: pid, cwd: file.cwd, updatedAt: file.updatedAt ?? file.startedAt ?? 0)
        }
    }

    /// The sessions of every account folder, and of ~/.claude (where plain `claude` runs) when its
    /// account is known. Sessions in a folder belong to that folder's account.
    public static func scan(accounts: [Account], homeAccount: UUID?) -> [(id: UUID, session: LiveSession)] {
        let home = homeAccount.map { [($0, Account.home.configDir)] } ?? []
        return (accounts.map { ($0.id, $0.configDir) } + home).flatMap { id, dir in
            read(dir: dir + "/sessions").map { (id, $0) }
        }
    }

    /// The account ~/.claude is signed in to: `matched` while it exists, else the account whose
    /// identity key is `profileKey`, from the profile in ~/.claude.json.
    public static func homeAccount(matched: UUID?, profileKey: String?, in accounts: [Account]) -> UUID? {
        accounts.first { $0.id == matched }?.id
            ?? profileKey.flatMap { key in accounts.first { $0.identity?.key == key }?.id }
    }

    /// True unless the process is gone. EPERM means it exists but belongs to another user.
    public static func isAlive(_ pid: Int32) -> Bool { pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) }

    /// The account of the live session with the greatest `updatedAt`, ignoring sessions that run in
    /// the probe directory. Falls back to `last` while it exists, then to the first account.
    public static func current(_ sessions: [(id: UUID, session: LiveSession)], accounts: [Account], last: UUID?,
                               probeDir: String = Paths.probeDir.path,
                               isAlive: (Int32) -> Bool = isAlive) -> UUID? {
        func standardized(_ path: String) -> String { (path as NSString).standardizingPath }
        let probe = standardized(probeDir)
        let latest = sessions.filter { isAlive($0.session.pid) && $0.session.cwd.map(standardized) != probe }
            .max { $0.session.updatedAt < $1.session.updatedAt }
        return latest?.id ?? accounts.first { $0.id == last }?.id ?? accounts.first?.id
    }
}
