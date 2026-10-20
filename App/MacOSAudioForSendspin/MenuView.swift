import AppKit
import SendspinServerKit
import SwiftUI

struct MenuView: View {
    @Bindable var bridge: BridgeController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            warnings
            if bridge.driverInstalled {
                groupVolume
                Divider()
                speakers
                if bridge.hasConnectedPlayers || bridge.isMacOutput {
                    Divider()
                    output
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Button("Settings…") {
                    // A menu bar app isn't active, so the window would open behind other apps.
                    NSApp.activate()
                    openSettings()
                }
                .keyboardShortcut(",")
                Button("Quit macOS Audio for Sendspin") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Text("Sendspin").font(.headline)
            Spacer()
            Label(statusText, systemImage: "circle.fill")
                .labelStyle(StatusLabelStyle(color: statusColor))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        if bridge.isStreaming { return "Streaming" }
        if bridge.hasConnectedPlayers { return "Idle" }
        return bridge.selected.isEmpty ? "No speakers selected" : "Connecting"
    }

    private var statusColor: Color {
        bridge.isStreaming ? .green : bridge.hasConnectedPlayers ? .secondary : .orange
    }

    @ViewBuilder private var warnings: some View {
        if !bridge.driverInstalled {
            Notice(text: "The Sendspin audio driver isn't installed.", systemImage: "exclamationmark.triangle.fill")
        } else if bridge.microphoneAccess == .denied || bridge.microphoneAccess == .restricted {
            Notice(text: "Allow microphone access so macOS Audio for Sendspin can capture the Sendspin output.",
                   systemImage: "mic.slash.fill") {
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                }
            }
        } else if bridge.isMacOutput && !bridge.hasConnectedPlayers {
            // The sound goes nowhere: offer the way back instead of silence.
            Notice(text: "The Mac's sound goes to Sendspin, but no speaker is connected.",
                   systemImage: "speaker.slash.fill") {
                Button("Use Previous Output") { Task { await bridge.setMacOutput(false) } }
                    .disabled(bridge.isSwitchingOutput)
            }
        } else if !bridge.isMacOutput && bridge.hasConnectedPlayers {
            Notice(text: "The Mac's sound isn't going to Sendspin.", systemImage: "speaker.slash.fill") {
                Button("Use Sendspin") { Task { await bridge.setMacOutput(true) } }
                    .disabled(bridge.isSwitchingOutput)
            }
        }
    }

    private var groupVolume: some View {
        HStack(spacing: 8) {
            Button {
                bridge.setGroupMuted(!bridge.deviceMuted)
            } label: {
                Image(systemName: bridge.deviceMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .help(bridge.deviceMuted ? "Unmute" : "Mute")
            Slider(value: Binding(get: { Double(bridge.deviceVolume) },
                                  set: { bridge.setGroupVolume(Float($0)) }),
                   in: 0...1)
                .controlSize(.small)
        }
        .disabled(!bridge.hasConnectedPlayers)
    }

    private var speakers: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Speakers").font(.subheadline).foregroundStyle(.secondary)
            if bridge.players.isEmpty {
                Text("Looking for Sendspin speakers…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(bridge.players) { player in
                PlayerRow(player: player, bridge: bridge)
            }
        }
    }

    private var output: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Switching to Sendspin without a connected speaker would silence the Mac;
            // switching back must always be possible.
            if bridge.hasConnectedPlayers || bridge.isMacOutput {
                Toggle("Use as Mac sound output", isOn: Binding(
                    get: { bridge.isMacOutput }, set: { enabled in Task { await bridge.setMacOutput(enabled) } }))
                    .disabled(bridge.isSwitchingOutput)
            }
            if let active = bridge.activeFormat {
                // Only formats a selected speaker supports; others get it converted.
                Picker("Format", selection: Binding(get: { active }, set: { bridge.selectFormat($0) })) {
                    ForEach(bridge.availableFormats) { format in
                        Text(format.label).tag(format)
                    }
                }
                .pickerStyle(.menu)
                .disabled(bridge.availableFormats.count < 2)
            }
        }
    }
}

private struct PlayerRow: View {
    let player: BridgeController.Player
    let bridge: BridgeController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { player.isSelected },
                                 set: { bridge.setSelected(player.instanceName, $0) })) {
                HStack {
                    Text(player.name).lineLimit(1)
                    Spacer()
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)

            if player.isSelected, player.status?.connection == .connected, let volume = player.status?.volume {
                HStack(spacing: 6) {
                    Image(systemName: player.status?.muted == true ? "speaker.slash" : "speaker.wave.1")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Slider(value: Binding(get: { Double(volume) },
                                          set: { bridge.setPlayerVolume(player.instanceName, Int($0.rounded())) }),
                           in: 0...100)
                        .controlSize(.mini)
                }
                .padding(.leading, 20)
            }
        }
    }

    private var statusText: String {
        guard player.isSelected else { return player.isDiscovered ? "" : "Offline" }
        guard player.isDiscovered else { return "Offline" }
        switch player.status?.connection {
        case .connected:
            // While streaming, show what this speaker actually receives.
            guard let format = player.status?.streamFormat else { return "Connected" }
            return BridgeController.StreamFormat(sampleRate: format.sampleRate, bitDepth: format.bitDepth).label
        case .taken: return "In use elsewhere"
        case .disconnected: return "Disconnected"
        case .failed: return "Can't connect"
        case .connecting, nil: return "Connecting…"
        }
    }
}

private struct Notice<Actions: View>: View {
    let text: String
    let systemImage: String
    @ViewBuilder var actions: Actions

    init(text: String, systemImage: String, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.text = text
        self.systemImage = systemImage
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(text, systemImage: systemImage)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            actions.controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct StatusLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(color).font(.system(size: 6))
            configuration.title
        }
    }
}
