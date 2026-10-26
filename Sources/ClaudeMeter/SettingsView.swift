import AppKit
import ClaudeMeterCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            accounts.tabItem { Label("Accounts", systemImage: "person.2") }
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 580, height: 460)
        .sheet(isPresented: $model.showAddAccount) { AddAccountSheet(model: model) }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }

    private var accounts: some View {
        VStack(alignment: .leading, spacing: 10) {
            List {
                ForEach(model.state.accounts) { AccountRow(model: model, account: $0) }
                    .onMove(perform: model.move)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            HStack {
                Button("Add Account…") { model.showAddAccount = true }
                Spacer()
                Text("Drag to reorder; the popover uses this order for ties. Double-click to rename.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }
}

struct AccountRow: View {
    let model: AppModel
    let account: Account
    @State private var confirmRemove = false
    @State private var renaming = false
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(account.name).font(.headline)
                Text(account.identity.map { joined([$0.email, $0.orgName, $0.plan]) } ?? "Not signed in yet")
                    .font(.caption).foregroundStyle(.secondary)
                Text(account.configDir).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
                if let other = model.duplicate(of: account) {
                    Label("Same email and organization as “\(other.name)”",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            Menu { actions } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Actions for \(account.name)")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: startRename)
        .contextMenu { actions }
        .alert("Rename Account", isPresented: $renaming) {
            TextField("Name", text: $draft)
            Button("Rename") { model.rename(account.id, to: draft) }.keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Remove “\(account.name)” from ClaudeMeter?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { model.remove(account.id) }
        } message: {
            Text("The folder \(account.configDir) is kept.")
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Rename…", action: startRename)
        Button("Sign In…") { model.signIn(account.id) }
        Divider()
        Button("Remove…", role: .destructive) { confirmRemove = true }
    }

    private func startRename() {
        draft = account.name
        renaming = true
    }
}

struct GeneralSettings: View {
    @State private var status = SMAppService.mainApp.status

    var body: some View {
        Form {
            Toggle("Launch at Login", isOn: Binding(get: { [.enabled, .requiresApproval].contains(status) },
                                                    set: { setLaunchAtLogin($0) }))
            if status == .requiresApproval {
                Text("Approve ClaudeMeter in System Settings > General > Login Items.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Login Items Settings…") { SMAppService.openSystemSettingsLoginItems() }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = SMAppService.mainApp.status
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        } catch {
            NSAlert(error: error).runModal()
        }
        status = SMAppService.mainApp.status
    }
}

struct AddAccountSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var accountID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Account").font(.headline)
            if let identity = model.account(accountID)?.identity {
                Label("Signed in as " + joined([identity.email, identity.orgName]),
                      systemImage: "checkmark.circle.fill")
            } else if accountID != nil {
                Text("Finish signing in with your browser. Waiting for sign-in…")
            } else {
                TextField("Name, for example ARC", text: $name)
                Text("ClaudeMeter creates a folder in ~/.claude-accounts and opens Terminal to sign in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                if accountID != nil {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Sign In…") { accountID = model.addAccount(named: name) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// While the Settings window is open the app is a regular app (Dock icon, Cmd-Tab entry), so the
/// user can return to it from Terminal or the browser. SettingsView's onDisappear undoes this.
@MainActor
enum SettingsWindow {
    static func open(_ openSettings: OpenSettingsAction) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        openSettings()
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            NSApp.activate()
            let window = NSApp.windows.first { $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" }
                ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
            window?.makeKeyAndOrderFront(nil)
            window?.orderFrontRegardless()
        }
    }
}
