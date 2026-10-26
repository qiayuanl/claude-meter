import AppKit
import ClaudeMeterCore
import Observation

/// App state and the serial queue of `claude` children. All views read this model.
/// A usage probe runs `claude -p /usage`; an identity check runs `claude auth status`.
@MainActor @Observable
final class AppModel {
    private(set) var state = AppState.load() { didSet { try? state.save() } }
    /// Latest result per account. A result without a snapshot keeps the previous snapshot.
    private(set) var results: [UUID: ProbeResult] = [:]
    /// Accounts that get no usage probes before the given time. In memory only.
    private(set) var rateLimitedUntil: [UUID: Date] = [:]
    /// Accounts with a `claude` child running.
    private(set) var running: Set<UUID> = []
    private(set) var currentID: UUID?
    /// Advances every 30 s so time-dependent views refresh.
    private(set) var now = Date()
    var showAddAccount = false

    private var queue: [Job] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var waitingForSignIn: Set<UUID> = []
    @ObservationIgnored private var lastProbeAll = Date.distantPast
    @ObservationIgnored private var signedInKeys = SessionDetector.KeyCache()

    private enum Job: Equatable {
        case usage(UUID), identity(UUID)
        var id: UUID { switch self { case .usage(let id), .identity(let id): id } }
    }

    /// At launch: identities, then usage of every account. Every 5 s: the session files, sign-in checks
    /// while the Add Account sheet is open, and a probe of all 5 min after the last one.
    init() {
        AccountSetup.removeLoginScripts()
        currentID = state.lastCurrentAccountID
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.waitingForSignIn.forEach { self?.enqueue(.identity($0)) } }
        }
        state.accounts.forEach { enqueue(.identity($0.id)) }
        probeAll()
        pollSessions()
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                pollSessions()
                if showAddAccount { waitingForSignIn.forEach { enqueue(.identity($0)) } }
                probeAll(atMostEvery: 300)
            }
        }
    }

    /// Accounts with a job queued or running.
    var busy: Set<UUID> { running.union(queue.map(\.id)) }

    var popoverAccounts: [Account] {
        state.accounts.popoverOrder(current: currentID, now: now) { results[$0]?.fresh(at: now) }
    }

    func account(_ id: UUID?) -> Account? { state.accounts.first { $0.id == id } }

    /// Another account signed in as the same email and organization.
    func duplicate(of account: Account) -> Account? {
        guard let key = account.identity?.key else { return nil }
        return state.accounts.first { $0.id != account.id && $0.identity?.key == key }
    }

    /// Queues a usage probe of every account unless the last one was less than `interval` ago.
    func probeAll(atMostEvery interval: TimeInterval = 0) {
        guard Date().timeIntervalSince(lastProbeAll) >= interval else { return }
        lastProbeAll = Date()
        state.accounts.forEach { enqueue(.usage($0.id)) }
    }

    private func enqueue(_ job: Job) {
        guard !queue.contains(job) else { return }
        queue.append(job)
        guard worker == nil else { return }
        worker = Task {
            while !queue.isEmpty {
                let job = queue.removeFirst()
                guard let account = account(job.id), let claude = await Claude.locate() else {
                    record(job.id, ProbeResult(error: ClaudeError.notFound.localizedDescription))
                    continue
                }
                running.insert(account.id)
                switch job {
                case .usage: await probe(account, with: claude)
                case .identity: await checkIdentity(account, with: claude)
                }
                running.remove(account.id)
            }
            worker = nil
        }
    }

    /// Stores a result for an existing account. A result without a snapshot keeps the previous one.
    private func record(_ id: UUID, _ result: ProbeResult) {
        guard account(id) != nil else { return }
        var result = result
        result.snapshot = result.snapshot ?? results[id]?.snapshot
        results[id] = result
    }

    /// Skips an account inside its 15 min rate-limit pause. Usage data for an account without an
    /// identity, or waiting for sign-in, also queues an identity check.
    private func probe(_ account: Account, with claude: Claude) async {
        if let until = rateLimitedUntil[account.id], until > Date() { return }
        let result = await claude.usage(account)
        rateLimitedUntil[account.id] = result.rateLimited ? Date().addingTimeInterval(15 * 60) : nil
        record(account.id, result)
        if result.snapshot != nil, account.identity == nil || waitingForSignIn.contains(account.id) {
            enqueue(.identity(account.id))
        }
    }

    private func checkIdentity(_ account: Account, with claude: Claude) async {
        let id = account.id
        let identity: Identity?
        do { identity = try await claude.identity(account) } catch { return }
        if identity == nil { record(id, ProbeResult(error: "Not signed in", signedOut: true)) }
        guard let identity, let i = state.accounts.firstIndex(where: { $0.id == id }) else { return }
        state.accounts[i].identity = identity
        if waitingForSignIn.remove(id) != nil || results[id]?.signedOut == true { enqueue(.usage(id)) }
    }

    private func pollSessions() {
        let folders = SessionDetector.scan(accounts: state.accounts, cache: &signedInKeys)
        currentID = SessionDetector.current(folders: folders, accounts: state.accounts, last: currentID)
        if let currentID, currentID != state.lastCurrentAccountID { state.lastCurrentAccountID = currentID }
        if Date().timeIntervalSince(now) >= 30 { now = Date() }
    }

    func addAccount(named rawName: String) -> UUID? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        do {
            let account = Account(name: name, configDir: try AccountSetup.createFolder(name: name))
            state.accounts.append(account)
            enqueue(.identity(account.id))
            signIn(account.id)
            return account.id
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }

    /// Opens Terminal with `claude auth login` for the account's folder.
    func signIn(_ id: UUID) {
        guard let account = account(id) else { return }
        Task {
            do {
                guard let claude = await Claude.locate() else { throw ClaudeError.notFound }
                let script = try AccountSetup.writeLoginScript(for: account, claude: claude.path)
                guard NSWorkspace.shared.open(script) else { throw ClaudeError("Could not open Terminal") }
                waitingForSignIn.insert(id)
            } catch {
                NSApp.activate()
                NSAlert(error: error).runModal()
            }
        }
    }

    func rename(_ id: UUID, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = state.accounts.firstIndex(where: { $0.id == id }) else { return }
        state.accounts[i].name = name
    }

    func move(from source: IndexSet, to destination: Int) {
        state.accounts.move(fromOffsets: source, toOffset: destination)
    }

    /// Forgets the account. Its folder stays. Queued jobs skip accounts that are gone.
    func remove(_ id: UUID) {
        state.accounts.removeAll { $0.id == id }
    }
}
