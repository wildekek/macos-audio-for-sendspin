import AppKit
import SendspinServerKit
import SwiftUI

struct SettingsView: View {
    @Bindable var bridge: BridgeController
    @State private var confirmingUninstall = false
    @State private var uninstalling = false
    @State private var uninstallError: String?
    @State private var openAtLogin = LoginItem.isEnabled
    @State private var loginItemNeedsApproval = LoginItem.needsApproval
    /// A pairing to forget, once confirmed: the server's (no `client_id`), or a speaker's.
    @State private var forgetting: (clientID: String?, name: String)?

    private static let repository = URL(string: "https://github.com/wildekek/macos-audio-for-sendspin")!
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var body: some View {
        Form {
            Section {
                if let active = bridge.activeFormat {
                    // Only formats a connected speaker supports; others get it converted.
                    Picker("Audio format", selection: Binding(get: { active }, set: { bridge.selectFormat($0) })) {
                        ForEach(bridge.availableFormats) { format in
                            Text(format.label).tag(format)
                        }
                    }
                    .disabled(bridge.availableFormats.count < 2)
                } else {
                    LabeledContent("Audio format", value: bridge.selectedFormat.label)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(bridge.activeFormat == nil
                     ? "Connect a speaker to choose from the formats it supports."
                     : "Speakers that can't play this format get the closest one they support.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            pairings
            allowedSources
            pairingHeldBack

            Section {
                Toggle("Open at login", isOn: Binding(get: { openAtLogin }, set: { setOpenAtLogin($0) }))
            } footer: {
                if loginItemNeedsApproval {
                    HStack {
                        Text("Switched off in System Settings.")
                        Button("Open Login Items…") { LoginItem.openSettings() }
                            .buttonStyle(.link)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent {
                    Button("Uninstall…", role: .destructive) { confirmingUninstall = true }
                        .disabled(uninstalling)
                } label: {
                    Text("Uninstall")
                    Text("Removes the Sendspin audio device and this app. Your settings are kept.")
                }
            } footer: {
                // A minimal about: the version, and where the source lives.
                HStack(spacing: 4) {
                    Text("macOS Audio for Sendspin \(version)")
                    Text("·")
                    Link("GitHub", destination: Self.repository)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            }
        }
        .formStyle(.grouped)
        .background(OpensOnActiveSpace())
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        // SwiftUI makes this view at launch and keeps it while the window is closed, so the
        // login item is read again each time: onboarding, or System Settings, may have changed it.
        .onAppear(perform: readLoginItem)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            readLoginItem()
        }
        .alert("Uninstall macOS Audio for Sendspin?", isPresented: $confirmingUninstall) {
            Button("Uninstall", role: .destructive) { uninstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Sendspin audio device and the app are removed, and you're asked for an administrator password. Mac audio stops for a moment; there's no need to restart.")
        }
        .alert("Forget \(forgetting?.name ?? "the pairing")?",
               isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            Button("Forget", role: .destructive) {
                guard let forgetting else { return }
                if let clientID = forgetting.clientID {
                    bridge.forgetPairing(clientID: clientID)
                } else {
                    bridge.forgetServerPairings()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(forgetting?.name ?? "It") and this Mac can't play together until you pair them again.")
        }
        .alert("Couldn't uninstall", isPresented: Binding(get: { uninstallError != nil },
                                                          set: { if !$0 { uninstallError = nil } })) {
            Button("OK") {}
        } message: {
            Text(uninstallError ?? "")
        }
    }

    /// What this Mac is paired with: the server it's a source for, and speakers it plays to,
    /// each with a way to forget it. Pairing itself happens in the menu.
    @ViewBuilder private var pairings: some View {
        let status = bridge.sourceStatus
        let serverPaired = status.hasPairing || status.paired
        let speakers = bridge.pairedSpeakerList
        if serverPaired || !speakers.isEmpty {
            Section("Paired") {
                if serverPaired {
                    LabeledContent {
                        Button("Forget…") { forgetting = (nil, bridge.sourceServerName) }
                    } label: {
                        Text(bridge.sourceServerName)
                    }
                }
                ForEach(speakers, id: \.clientID) { speaker in
                    LabeledContent {
                        Button("Forget…") { forgetting = (speaker.clientID, speaker.name) }
                    } label: {
                        Text(speaker.name)
                    }
                }
            }
        }
    }

    /// Sources allowed to play unpaired, each with a way to take that back. Allowing happens in
    /// the menu, the first time a source is chosen.
    @ViewBuilder private var allowedSources: some View {
        let sources = bridge.approvedSourceList
        if !sources.isEmpty {
            Section {
                ForEach(sources, id: \.instanceName) { source in
                    LabeledContent {
                        Button("Remove") { bridge.removeSourceApproval(source.instanceName) }
                    } label: {
                        Text(source.name)
                    }
                }
            } header: {
                Text("Allowed sources")
            } footer: {
                Text("A removed source asks again before it plays. A paired source needs no permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// After too many wrong codes, pairing by code waits for the user (pairing.md, Rounds).
    @ViewBuilder private var pairingHeldBack: some View {
        if bridge.sourceStatus.pairingHeldBack {
            Section {
                LabeledContent {
                    Button("Allow Pairing") { bridge.allowPairingAgain() }
                } label: {
                    Text("Pairing held back")
                    Text("After 20 wrong codes, no server can pair with this Mac until you allow it.")
                }
            }
        }
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.set(enabled)
        } catch {
            Log.warning("Couldn't change the login item: \(error)")
        }
        readLoginItem()
    }

    private func readLoginItem() {
        openAtLogin = LoginItem.isEnabled
        loginItemNeedsApproval = LoginItem.needsApproval
    }

    private func uninstall() {
        uninstalling = true
        Task {
            defer { uninstalling = false }
            do {
                if try await bridge.uninstall() {
                    NSApp.terminate(nil)
                }
            } catch {
                uninstallError = error.localizedDescription
            }
        }
    }
}

/// Settings opens on the Space the user is on. SwiftUI keeps the window between openings, on
/// the Space it was last on, and activating the app would switch to that Space instead.
private struct OpensOnActiveSpace: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { View() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class View: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.collectionBehavior.insert(.moveToActiveSpace)
        }
    }
}
