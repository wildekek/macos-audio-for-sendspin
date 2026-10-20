import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var bridge: BridgeController
    @State private var confirmingUninstall = false
    @State private var uninstalling = false
    @State private var uninstallError: String?

    var body: some View {
        Form {
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

            Section {
                LabeledContent {
                    Button("Uninstall…", role: .destructive) { confirmingUninstall = true }
                        .disabled(uninstalling)
                } label: {
                    Text("Uninstall")
                    Text("Removes the Sendspin audio device, this app and its microphone permission. Your settings are kept.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .alert("Uninstall macOS Audio for Sendspin?", isPresented: $confirmingUninstall) {
            Button("Uninstall", role: .destructive) { uninstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Sendspin audio device and the app are removed, and you're asked for an administrator password. Mac audio stops for a moment; there's no need to restart.")
        }
        .alert("Couldn't uninstall", isPresented: Binding(get: { uninstallError != nil },
                                                          set: { if !$0 { uninstallError = nil } })) {
            Button("OK") {}
        } message: {
            Text(uninstallError ?? "")
        }
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
