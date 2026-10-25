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

            Section {
                Picker("Speaker buffer", selection: Binding(get: { bridge.lead }, set: { bridge.setLead($0) })) {
                    Text("300 ms").tag(BridgeController.Lead.low)
                    Text("600 ms").tag(BridgeController.Lead.normal)
                    Text("1 s").tag(BridgeController.Lead.robust)
                }
                .pickerStyle(.segmented)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Longer buffers survive Wi-Fi hiccups. Video apps are told the delay to keep lip sync.")
                    if let requirement = bridge.leadRequirement {
                        Text("Using \(requirement.ms) ms: \(requirement.name) needs at least that much.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            pairedServer
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
