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
                Divider()
                speakers
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

    /// Where the Mac's sound plays, and the one switch between Sendspin and the other output.
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Playing on \(bridge.isMacOutput ? "Sendspin" : bridge.currentOutputName ?? "this Mac")")
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                // Green while audio is going out to the speakers.
                if bridge.isStreaming {
                    HStack(spacing: 4) {
                        Image(systemName: "circle.fill").foregroundStyle(.green).font(.system(size: 6))
                        Text("Streaming")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            if let action = switchAction {
                Button(action.title) { Task { await bridge.setMacOutput(action.toSendspin) } }
                    .disabled(bridge.isSwitchingOutput)
            }
        }
    }

    /// Switching to Sendspin needs a connected speaker, or the Mac would go silent;
    /// switching back is always offered.
    private var switchAction: (title: String, toSendspin: Bool)? {
        if bridge.isMacOutput {
            return bridge.returnOutputName.map { ("Use \($0)", false) }
        }
        guard bridge.driverInstalled, bridge.hasConnectedPlayers else { return nil }
        return ("Use Sendspin", true)
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
        }
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
                        .help(statusHelp)
                }
            }
            .toggleStyle(.checkbox)

            if player.isSelected, player.status?.connection == .connected, player.status?.canSetVolume == true,
               let volume = player.status?.volume {
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
        case .pairingRequired: return "Needs pairing"
        case .notApproved: return "Identity changed"
        case .disconnected: return "Disconnected"
        case .failed: return "Can't connect"
        case .connecting, nil: return "Connecting…"
        }
    }

    private var statusHelp: String {
        switch player.status?.connection {
        case .pairingRequired:
            "This speaker only plays for paired servers, and pairing isn't supported yet."
        case .notApproved:
            "This speaker presents a different identity than the one you allowed. "
                + "If you trust it, untick and tick it again."
        default:
            ""
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
