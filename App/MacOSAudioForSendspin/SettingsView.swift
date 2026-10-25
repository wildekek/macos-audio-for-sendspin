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
            unpairedSpeakers
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
            if forgetting?.clientID == nil {
                Text("\(forgetting?.name ?? "It") and this Mac can't play together until you pair them again.")
            } else {
                // Forgotten, a speaker is unticked: new again (the server guide).
                Text("\(forgetting?.name ?? "It") stops playing and becomes a new speaker: pair it again, "
                     + "or tick it in the menu to let it play unpaired.")
            }
        }
        .alert("Couldn't uninstall", isPresented: Binding(get: { uninstallError != nil },
                                                          set: { if !$0 { uninstallError = nil } })) {
            Button("OK") {}
        } message: {
            Text(uninstallError ?? "")
        }
    }

    /// What this Mac is paired with: the server it's a source for, and speakers it plays to,
    /// each with a way to forget it. Speakers are paired under Not paired, or from the menu.
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

    /// Speakers on the network that aren't paired, each with Pair…: what pairing asks for shows
    /// under it, as under its row in the menu. Paired, it moves up.
    @ViewBuilder private var unpairedSpeakers: some View {
        let speakers = bridge.unpairedSpeakerList
        if !speakers.isEmpty {
            Section {
                ForEach(speakers, id: \.instanceName) { speaker in
                    let pairing = isPairing(speaker.instanceName)
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent {
                            if !pairing {
                                Button("Pair…") { bridge.pairFromSettings(speaker.instanceName) }
                            }
                        } label: {
                            Text(speaker.name)
                            Text(speaker.allowed ? "Plays unpaired" : "New")
                        }
                        if pairing {
                            HStack(alignment: .top, spacing: 8) {
                                pairingCaption(speaker.instanceName, name: speaker.name)
                                Button("Cancel") { bridge.cancelPairing(speaker.instanceName) }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            } header: {
                Text("Not paired")
            } footer: {
                Text("Only a paired speaker is sure to be yours: another device with its name can't take its place.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func isPairing(_ name: String) -> Bool {
        bridge.speakerPairing?.name == name || bridge.tokenEntry?.name == name
    }

    /// The menu's captions, without its indent.
    @ViewBuilder private func pairingCaption(_ instanceName: String, name: String) -> some View {
        let methods = bridge.pairMethods(for: instanceName)
        if let entry = bridge.tokenEntry, entry.name == instanceName {
            tokenCaption(instanceName, name: name, phase: .looking(again: entry.again))
        } else if let pairing = bridge.speakerPairing, pairing.name == instanceName {
            if case .token = pairing.method {
                tokenCaption(instanceName, name: name, phase: pairing.progress == .paired ? .paired : .pairing)
            } else {
                PairingCaption(pairing: pairing, speaker: name, methods: methods, bridge: bridge, indent: 0)
            }
        }
    }

    private func tokenCaption(_ instanceName: String, name: String, phase: TokenCaption.Phase) -> some View {
        TokenCaption(speaker: name, locations: bridge.pairMethods(for: instanceName)?.pairingPSK ?? [], phase: phase,
                     scanning: bridge.scanning == instanceName, indent: 0,
                     onScan: { bridge.startScanning(instanceName) }) { token in
            bridge.pairWithToken(instanceName, token: token)
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
