import AppKit
import ClaudeMeterCore
import SwiftUI

struct PopoverView: View {
    let model: AppModel
    /// Lays out every account without a scroll view, for ImageRenderer.
    var forImage = false
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var listHeight: CGFloat = 120

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Claude Usage").font(.headline)
                Spacer()
                Button { model.probeAll(atMostEvery: 60) } label: { refreshIcon(spinning: model.running != nil) }
                    .help("Refresh").accessibilityLabel("Refresh")
                Button(action: { SettingsWindow.open(openSettings) }) { Image(systemName: "gearshape") }
                    .help("Settings").accessibilityLabel("Settings")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if model.forecast.accounts > 0 {
                PoolHeader(forecast: model.forecast, now: model.now).padding(.horizontal, 14).padding(.vertical, 8)
                Divider()
            }
            let list = VStack(spacing: 0) {
                if model.state.accounts.isEmpty {
                    Text("No accounts. Add one in Settings.")
                        .foregroundStyle(.secondary).padding(.vertical, 10)
                }
                ForEach(Array(model.popoverAccounts.enumerated()), id: \.element.id) { index, account in
                    if index > 0 { Divider() }
                    AccountSection(model: model, account: account).padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 14)
            if forImage {
                list
            } else {
                ScrollView {
                    list.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .frame(height: min(listHeight, 560))
            }
            Divider()
            HStack(spacing: 14) {
                Button("Settings…", action: { SettingsWindow.open(openSettings) })
                Spacer()
                Button("Quit ClaudeMeter") { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
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
                        tag("In use")
                    } else if account.id == model.forecast.next {
                        tag("Next").help("Switch to this account next: it has the most room per hour left before its weekly reset.")
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

    private func tag(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.medium)).padding(.horizontal, 6)
            .padding(.vertical, 1).background(.quaternary, in: Capsule())
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
        } else if result.snapshot == nil, model.isBusy(account.id) {
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

    /// Time left, e.g. "in 46 min", "in 3 h 46 min" or "in 2 days 5 h"; "Not started" for an idle session.
    private var reset: String {
        guard let date = limit.resetsAt, date > now else { return limit.kind == "session" ? "Not started" : "" }
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        let (days, hours) = (minutes / 1440, minutes % 1440 / 60)
        if days > 0 { return "in \(days) \(days == 1 ? "day" : "days")" + (hours > 0 ? " \(hours) h" : "") }
        return hours > 0 ? "in \(hours) h \(minutes % 60) min" : "in \(minutes) min"
    }

    var body: some View {
        let percent = limit.percent(at: now)
        HStack(spacing: 8) {
            Text(title).lineLimit(1).frame(width: 52, alignment: .leading).help(title)
            Capsule().fill(.quaternary).frame(height: 5).overlay(alignment: .leading) {
                GeometryReader { bar in
                    Capsule().fill(warningColor(percent) ?? .accentColor)
                        .frame(width: bar.size.width * min(max(percent, 0), 100) / 100)
                }
            }
            Text("\(Int(percent.rounded()))%").monospacedDigit().frame(width: 38, alignment: .trailing)
            Text(reset).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: 84, alignment: .leading)
        }
        .font(.callout)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(Int(percent.rounded())) percent used" + (reset.isEmpty ? "" : ", \(reset)"))
    }
}

/// All accounts as one pool: the weekly room left (the bar), the room that even use of each account would
/// leave (the tick), the daily budget until the tightest refill, and the forecast at your pace. 1 account is one
/// account's weekly limit.
struct PoolHeader: View {
    let forecast: Forecast
    let now: Date

    private func accounts(_ pp: Double) -> String { String(format: "%.1f", pp / 100) }

    /// "now", "5 PM" or "4:20 PM" today, "Wed 5 PM" within 6 days, else "Nov 8, 2 PM". Rounded to the
    /// minute, because resets can arrive a fraction of a second before the hour.
    private func when(_ exact: Date?) -> String {
        guard let exact, exact > now else { return "now" }
        let date = Date(timeIntervalSince1970: (exact.timeIntervalSince1970 / 60).rounded() * 60)
        let calendar = Calendar.current
        let time: Date.FormatStyle = calendar.component(.minute, from: date) == 0 ? .dateTime.hour() : .dateTime.hour().minute()
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(time) }
        let sixDays = calendar.date(byAdding: .day, value: 6, to: calendar.startOfDay(for: now)) ?? now
        return date.formatted(date < sixDays ? time.weekday(.abbreviated) : time.month(.abbreviated).day())
    }

    /// "Up to 1.3 a day until the Wed 5 PM refill", plus ", with 2 refills before it" when earlier resets
    /// count. Nil when no weekly reset is known.
    private var refill: String? {
        guard let refill = forecast.refill else { return nil }
        let room = refill.room < 1 ? "No room" : "Up to \(accounts(refill.perDay)) a day"
        let earlier = refill.refills == 0 ? "" : ", with \(refill.refills) refill\(refill.refills == 1 ? "" : "s") before it"
        return "\(room) until the \(when(refill.date)) refill" + earlier
    }

    /// Red: runs out at your pace (by that time when only a lower bound of the pace is known). Orange: room
    /// expires unused at your measured pace. Green: lasts at your measured pace.
    private var verdict: (text: String, color: Color)? {
        guard let o = forecast.outcome else { return nil }
        let bound = forecast.paceIsLowerBound
        if o.runsOut, let start = o.runOut { return ("Runs out \(bound ? "by " : "")\(when(start)) at your pace", .red) }
        guard !bound else { return nil }
        return o.unused > 10 ? ("~\(accounts(o.unused)) expires unused by \(when(o.unusedBy))", .orange)
            : ("Lasts the week at your pace", .green)
    }

    var body: some View {
        let total = Double(forecast.accounts) * 100
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("All accounts").font(.headline)
                Spacer()
                Text("\(accounts(forecast.left)) of \(forecast.accounts) left").monospacedDigit()
            }
            Capsule().fill(.quaternary).frame(height: 6).overlay(alignment: .leading) {
                GeometryReader { bar in
                    Capsule().fill(Color.accentColor).frame(width: bar.size.width * min(1, forecast.left / total))
                    Rectangle().fill(.primary).frame(width: 2, height: 12)
                        .offset(x: bar.size.width * min(1, forecast.steadyLeft / total) - 1, y: -3)
                }
            }
            .padding(.vertical, 3)
            if let refill { Text(refill).font(.caption).foregroundStyle(.secondary) }
            if let verdict {
                HStack(spacing: 6) {
                    Circle().fill(verdict.color).frame(width: 6, height: 6)
                    Text(verdict.text).foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("The bar is the weekly room left in all accounts. The tick is the room left if every account "
              + "had been used at an even rate that reaches 100 % at its weekly reset. The line below is the "
              + "most you can use per day, on average, without running out before a weekly reset.")
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
