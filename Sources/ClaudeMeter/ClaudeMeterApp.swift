import AppKit
import ClaudeMeterCore
import SwiftUI

@main
@MainActor
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--probe-once") {
            guard i + 1 < args.count else {
                FileHandle.standardError.write(Data("usage: ClaudeMeter --probe-once <folder>\n".utf8))
                exit(2)
            }
            Task { exit(await probeOnce(folder: args[i + 1]) ? 0 : 1) }
            dispatchMain()
        }
        if let i = args.firstIndex(of: "--render-previews"), i + 1 < args.count {
            do { try Previews.render(to: URL(filePath: args[i + 1])) } catch { print(error); exit(1) }
            exit(0)
        }
        ClaudeMeterApp.main()
    }

    /// `--probe-once <folder>`: prints the parsed result of one probe as JSON. True on success.
    static func probeOnce(folder: String) async -> Bool {
        let claude = await Claude.locate()
        let result = await claude?.usage(Account(name: "probe", configDir: folder))
            ?? ProbeResult(error: ClaudeError.notFound.localizedDescription)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: (try? encoder.encode(result)) ?? Data(), as: UTF8.self))
        return result.error == nil
    }
}

struct ClaudeMeterApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model).buttonStyle(.borderless)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}

func warningColor(_ percent: Double) -> Color? {
    percent >= 95 ? .red : percent >= 80 ? .orange : nil
}

/// Gauge and tightest percent of the account in use, as an NSImage because a MenuBarExtra label
/// drops SwiftUI colors: a template below 80 % (AppKit tints it), else orange or red as drawn.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let account = model.account(model.currentID)
        let percent = account.flatMap { model.results[$0.id]?.fresh(at: model.now) }?.tightestPercent(at: model.now)
        let text = percent.map { "\(Int($0.rounded()))%" } ?? "–"
        Image(nsImage: Self.render(percent: percent ?? 0, text: text))
            .accessibilityLabel(["Claude usage", account?.name, text].compactMap { $0 }.joined(separator: " "))
    }

    /// The image holds a 1x and a 2x bitmap; AppKit picks the one matching each screen.
    static func render(percent: Double, text: String) -> NSImage {
        let step: Double = [0, 33, 50, 67, 100].min { abs($0 - percent) < abs($1 - percent) } ?? 0
        let color = warningColor(percent)
        let view = HStack(spacing: 4) {
            Image(systemName: "gauge.with.dots.needle.\(Int(step))percent").font(.system(size: 14))
            Text(text).font(.system(size: 13).monospacedDigit())
        }
        .foregroundStyle(color ?? .black)
        .fixedSize()
        .padding(.vertical, 2)
        let renderer = ImageRenderer(content: view)
        let image = NSImage()
        for scale in [1.0, 2.0] {
            renderer.scale = scale
            guard let cg = renderer.cgImage else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale)
            image.addRepresentation(rep)
            image.size = rep.size
        }
        image.isTemplate = color == nil
        return image
    }
}
