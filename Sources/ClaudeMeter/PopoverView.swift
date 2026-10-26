import AppKit
import ClaudeMeterCore
import SwiftUI

struct PopoverView: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var listHeight: CGFloat = 120

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Claude Usage").font(.headline)
                Spacer()
                Button { model.probeAll(atMostEvery: 60) } label: { refreshIcon(spinning: !model.running.isEmpty) }
                    .help("Refresh").accessibilityLabel("Refresh")
                Button(action: { SettingsWindow.open(openSettings) }) { Image(systemName: "gearshape") }
                    .help("Settings").accessibilityLabel("Settings")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    if model.state.accounts.isEmpty {
                        Text("No accounts. Choose Add Account… to start.")
                            .foregroundStyle(.secondary).padding(.vertical, 10)
                    }
                    ForEach(Array(model.popoverAccounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 { Divider() }
                        AccountSection(model: model, account: account).padding(.vertical, 10)
                    }
                }
                .padding(.horizontal, 14)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .frame(height: min(listHeight, 560))
            Divider()
            HStack(spacing: 14) {
                Button("Add Account…") {
                    model.showAddAccount = true
                    SettingsWindow.open(openSettings)
                }
                Button("Settings…", action: { SettingsWindow.open(openSettings) })
                Spacer()
                Button("Quit ClaudeMeter") { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .buttonStyle(.borderless)
        .frame(width: 340)
    }

    /// Spins while a probe runs; static when Reduce Motion is on.
    private func refreshIcon(spinning: Bool) -> some View {
        TimelineView(.animation(paused: !spinning || reduceMotion)) { context in
            let turns = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
            Image(systemName: "arrow.clockwise").rotationEffect(.degrees(spinning && !reduceMotion ? turns * 360 : 0))
        }
    }
}

struct AccountSection: View {
    let model: AppModel
    let account: Account

    var body: some View {
        let result = model.results[account.id] ?? ProbeResult()
        let now = model.now
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(account.name).font(.headline).lineLimit(1)
                    if account.id == model.currentID {
                        Text("In use").font(.caption2.weight(.medium)).padding(.horizontal, 6)
                            .padding(.vertical, 1).background(.quaternary, in: Capsule())
                    }
                    Spacer()
                    Text(account.identity?.plan ?? "").foregroundStyle(.secondary)
                }
                let subtitle = joined([account.identity?.orgName, account.identity?.email])
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .help(result.snapshot.map { "Updated " + $0.asOf.formatted(date: .abbreviated, time: .shortened) } ?? "")
            if !result.signedOut, let snapshot = result.snapshot {
                VStack(spacing: 3) {
                    let limits = [snapshot.session, snapshot.weekly].compactMap { $0 } + snapshot.scoped
                    ForEach(Array(limits.enumerated()), id: \.offset) { LimitRow(limit: $1, now: now) }
                }
                if let extra = snapshot.extraUsage, extra.isEnabled {
                    Text(extraUsage(extra)).font(.caption)
                }
            }
            problem(result, now: now).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// A caption only when something is wrong or the first probe is pending.
    @ViewBuilder
    private func problem(_ result: ProbeResult, now: Date) -> some View {
        if result.signedOut {
            HStack(spacing: 4) {
                Text("Not signed in —")
                Button("Sign In…") { model.signIn(account.id) }.buttonStyle(.link)
            }
        } else if let until = model.rateLimitedUntil[account.id], until > now {
            Text("Rate limited")
        } else if let error = result.error {
            Text(error).lineLimit(2)
        } else if result.snapshot == nil, model.busy.contains(account.id) {
            Text("Checking…")
        }
    }
}

/// One limit: name, bar, percent and reset. Fixed column widths align rows across accounts.
struct LimitRow: View {
    let limit: UsageLimit
    let now: Date

    private var title: String {
        switch limit.kind {
        case "session": "Session"
        case "weekly_all": "Week"
        default: limit.model ?? "Model"
        }
    }

    /// Session: time left, e.g. "in 3 h 46 min", or "Not started". Weekly: e.g. "Sun 12:00 AM".
    private var reset: String {
        let isSession = limit.kind == "session"
        guard let date = limit.resetsAt, date > now else { return isSession ? "Not started" : "" }
        guard isSession else { return date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        return minutes >= 60 ? "in \(minutes / 60) h \(minutes % 60) min" : "in \(minutes) min"
    }

    var body: some View {
        let percent = limit.percent(at: now)
        HStack(spacing: 8) {
            Text(title).lineLimit(1).frame(width: 52, alignment: .leading).help(title)
            ProgressView(value: min(max(percent, 0), 100), total: 100)
                .progressViewStyle(.linear).controlSize(.small).tint(warningColor(percent) ?? .accentColor)
            Text("\(Int(percent.rounded()))%").monospacedDigit().frame(width: 38, alignment: .trailing)
            Text(reset).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: 84, alignment: .leading)
        }
        .font(.callout)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(Int(percent.rounded())) percent used" + (reset.isEmpty ? "" : ", \(reset)"))
    }
}

func joined(_ parts: [String?]) -> String {
    parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
}

private func extraUsage(_ extra: ExtraUsage) -> String {
    let format = FloatingPointFormatStyle<Double>.Currency(code: extra.currency ?? "USD")
    let used = ((extra.usedCredits ?? 0) / 100).formatted(format)
    let limit = extra.monthlyLimit.map { " of " + ($0 / 100).formatted(format) } ?? ""
    return "Extra usage \(used)\(limit)"
}
