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
    @State private var confirmingForget = false
    @State private var forgettingSpeaker: String?

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

            pairedServer
            pairingHeldBack
            pairedSpeakers

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
        .alert("Forget the pairing with \(bridge.sourceServerName)?", isPresented: $confirmingForget) {
            Button("Forget", role: .destructive) { bridge.forgetServerPairings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(bridge.sourceServerName) can't play the Mac's audio until you pair it again.")
        }
        .alert("Couldn't uninstall", isPresented: Binding(get: { uninstallError != nil },
                                                          set: { if !$0 { uninstallError = nil } })) {
            Button("OK") {}
        } message: {
            Text(uninstallError ?? "")
        }
    }

    /// Once paired: which server, and a way to forget it. Pairing itself happens in the menu.
    @ViewBuilder private var pairedServer: some View {
        let status = bridge.sourceStatus
        if status.hasPairing || status.paired {
            Section {
                LabeledContent {
                    Button("Forget…") { confirmingForget = true }
                } label: {
                    Text(bridge.sourceServerName)
                    Text(status.connected ? "Paired" : "Paired, not connected right now")
                }
            }
        }
    }

    /// Speakers this Mac is paired with, to forget one.
    @ViewBuilder private var pairedSpeakers: some View {
        if !bridge.pairedSpeakerList.isEmpty {
        Section {
            ForEach(bridge.pairedSpeakerList, id: \.clientID) { speaker in
                LabeledContent {
                    Button("Forget…") { forgettingSpeaker = speaker.clientID }
                } label: {
                    Text(speaker.name)
                    Text("Paired")
                }
            }
        } header: {
            Text("Paired speakers")
        } footer: {
            Text("A paired speaker knows this Mac by a key of its own. Pair a speaker from its row in the menu.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .alert("Forget the pairing?", isPresented: Binding(get: { forgettingSpeaker != nil },
                                                          set: { if !$0 { forgettingSpeaker = nil } })) {
            Button("Forget", role: .destructive) {
                if let clientID = forgettingSpeaker { bridge.forgetPairing(clientID: clientID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The speaker forgets this Mac too, if it's on. To play on it again, it may need pairing again.")
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
