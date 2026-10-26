import AppKit
import ClaudeMeterCore
import SwiftUI

/// `ClaudeMeter --render-previews <dir>`: README images of fictional accounts, drawn at 2x.
@MainActor
enum Previews {
    /// Thursday 2026-03-12 1:00 PM in Los Angeles, so reset times are the same on every run.
    static let now = Date(timeIntervalSince1970: 1_773_345_600)

    static func render(to dir: URL) throws {
        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!
        let model = demoModel()
        for scheme in [ColorScheme.light, .dark] {
            try save(PopoverView(model: model, forImage: true).buttonStyle(LabelOnly())
                .background(Color(nsColor: .windowBackgroundColor)).clipShape(.rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary)),
                scheme, to: dir.appending(path: "popover-\(scheme).png"))
        }
        try save(VStack(spacing: 0) {
            ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
                HStack(spacing: 20) {
                    ForEach([42.0, 86, 97], id: \.self) { Image(nsImage: MenuBarLabel.render(percent: $0, text: "\(Int($0))%")) }
                }
                .foregroundStyle(scheme == .light ? .black : .white)
                .padding(.horizontal, 16).frame(height: 26).frame(maxWidth: .infinity)
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme)
            }
        }
        .clipShape(.rect(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary)),
        .light, to: dir.appending(path: "menubar.png"))
    }

    /// Four accounts in an order that the popover sorts; "Personal" is in use.
    private static func demoModel() -> AppModel {
        func limit(_ kind: String, _ percent: Double, minutes: Double?, model: String? = nil) -> UsageLimit {
            UsageLimit(kind: kind, percent: percent, resetsAt: minutes.map { now + $0 * 60 }, model: model)
        }
        let demo: [(name: String, identity: Identity, limits: [UsageLimit])] = [
            ("Work", Identity(email: "alex@acme.dev", orgName: "Acme Robotics", subscriptionType: "team"),
             [limit("session", 0, minutes: nil), limit("weekly_all", 99, minutes: 68 * 60)]),
            ("Side project", Identity(email: "sam@example.com", orgName: "Side Project", subscriptionType: "pro"),
             [limit("session", 100, minutes: 125), limit("weekly_all", 100, minutes: 120 * 60)]),
            ("Personal", Identity(email: "alex@example.com", orgName: "Personal", subscriptionType: "max"),
             [limit("session", 27, minutes: 226), limit("weekly_all", 69, minutes: 28 * 60),
              limit("weekly_scoped", 48, minutes: 28 * 60, model: "Fable")]),
            ("Lab", Identity(email: "alex@lab.example.edu", orgName: "Example Lab", subscriptionType: "team"),
             [limit("session", 100, minutes: 72), limit("weekly_all", 18, minutes: 100 * 60)]),
        ]
        var state = AppState()
        state.accounts = demo.map { Account(name: $0.name, configDir: "", identity: $0.identity) }
        var results: [UUID: ProbeResult] = [:]
        for (account, d) in zip(state.accounts, demo) {
            results[account.id] = ProbeResult(snapshot: UsageSnapshot(limits: d.limits, asOf: now - 120))
        }
        return AppModel(demo: state, results: results, currentID: state.accounts[2].id, now: now)
    }

    private static func save(_ view: some View, _ scheme: ColorScheme, to url: URL) throws {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw ClaudeError("Could not render \(url.lastPathComponent)") }
        try png.write(to: url)
    }

    /// Draws a button as its label: ImageRenderer cannot draw AppKit-backed buttons.
    private struct LabelOnly: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View { configuration.label }
    }
}
