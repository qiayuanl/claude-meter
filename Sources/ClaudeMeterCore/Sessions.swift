import Foundation

/// A Claude Code session, from `<folder>/sessions/<pid>.json`.
public struct LiveSession: Sendable, Equatable {
    var pid: Int32
    var cwd: String?
    /// Milliseconds since 1970.
    var updatedAt: Double
}

/// One scanned `sessions` folder: its account (nil for ~/.claude), its current login's key, its sessions.
public struct FolderSessions: Sendable {
    var accountID: UUID?
    var signedInKey: String?
    var sessions: [LiveSession]
}

/// Finds the account the user works in: the one whose live session was updated last.
public enum SessionDetector {
    /// Signed-in key per global config path, with the modification time and size it was read at.
    public typealias KeyCache = [String: (stamp: String, key: String?)]

    /// Reads every `<digits>.json` file in `dir`. Other files (such as `<pid>.<hash>.key`) are never opened.
    static func read(dir: String) -> [LiveSession] {
        struct File: Decodable { var cwd: String?, updatedAt: Double?, startedAt: Double? }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.compactMap { name in
            guard name.hasSuffix(".json") else { return nil }
            let stem = name.dropLast(5)
            guard !stem.isEmpty, stem.allSatisfy({ ("0"..."9").contains($0) }), let pid = Int32(stem),
                  let data = FileManager.default.contents(atPath: dir + "/" + name),
                  let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
            return LiveSession(pid: pid, cwd: file.cwd, updatedAt: file.updatedAt ?? file.startedAt ?? 0)
        }
    }

    /// Scans every account folder and ~/.claude, where plain `claude` runs. A folder's global config
    /// (~/.claude.json for ~/.claude) is read only for sessions, and again only when it changes.
    public static func scan(accounts: [Account], cache: inout KeyCache,
                            home: String = Paths.home) -> [FolderSessions] {
        let folders = accounts.map { ($0.id as UUID?, $0.configDir, $0.configDir + "/.claude.json") }
            + [(nil, home + "/.claude", home + "/.claude.json")]
        return folders.map { id, dir, config in
            let sessions = read(dir: dir + "/sessions")
            guard !sessions.isEmpty, let attributes = try? FileManager.default.attributesOfItem(atPath: config) else {
                return FolderSessions(accountID: id, signedInKey: nil, sessions: sessions)
            }
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let stamp = "\(modified)|\(attributes[.size] ?? 0)"
            if cache[config]?.stamp != stamp { cache[config] = (stamp, GlobalConfig.read(config)?.signedInKey) }
            return FolderSessions(accountID: id, signedInKey: cache[config]?.key, sessions: sessions)
        }
    }

    /// True unless the process is gone. EPERM means it exists but belongs to another user.
    public static func isAlive(_ pid: Int32) -> Bool { pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) }

    /// The account a folder's sessions run as: the account whose identity matches the folder's
    /// current login (which follows `/login` switches), else the folder's own account.
    static func owner(of folder: FolderSessions, in accounts: [Account]) -> UUID? {
        let own = accounts.first { $0.id == folder.accountID }
        guard let key = folder.signedInKey, own?.identity?.key != key else { return own?.id }
        return accounts.first { $0.identity?.key == key }?.id ?? own?.id
    }

    /// The owner of the live session with the greatest `updatedAt`, ignoring sessions that run in
    /// the probe directory. Falls back to `last` while it exists, then to the first account.
    public static func current(folders: [FolderSessions], accounts: [Account], last: UUID?,
                               probeDir: String = Paths.probeDir.path,
                               isAlive: (Int32) -> Bool = isAlive) -> UUID? {
        func standardized(_ path: String) -> String { (path as NSString).standardizingPath }
        let probe = standardized(probeDir)
        let live = folders.flatMap { folder -> [(id: UUID, updatedAt: Double)] in
            guard let owner = owner(of: folder, in: accounts) else { return [] }
            return folder.sessions.filter { isAlive($0.pid) && $0.cwd.map(standardized) != probe }
                .map { (owner, $0.updatedAt) }
        }
        let latest = live.max { $0.updatedAt < $1.updatedAt }
        return latest?.id ?? accounts.first { $0.id == last }?.id ?? accounts.first?.id
    }
}
