import AppKit
import SendspinServerKit
import SwiftUI

struct MenuView: View {
    @Bindable var bridge: BridgeController
    @Environment(\.openSettings) private var openSettings
    @State private var driverError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            warnings
            if bridge.driverInstalled {
                Divider()
                speakers
            }
            Divider()
            HStack {
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
                Spacer()
                Button {
                    // A menu bar app isn't active, so the window would open behind other apps.
                    NSApp.activate()
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .keyboardShortcut(",")
                .help("Settings")
                .accessibilityLabel("Settings")
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 340)
    }

    /// Where the Mac's sound plays, and the one switch between Sendspin and the other output.
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Centred, not on the baseline: a caption on a headline's baseline looks low.
            HStack(alignment: .center) {
                Text("Playing on \(bridge.isMacOutput ? "Sendspin" : bridge.currentOutputName ?? "this Mac")")
                    .font(.headline)
                    .lineLimit(1)
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
        if bridge.driverNeedsRestart || (!bridge.driverInstalled && bridge.driverState != .notInstalled) {
            Notice(text: "The audio driver is installed, but macOS hasn't loaded it. Restart your Mac to finish.",
                   systemImage: "arrow.clockwise.circle.fill")
        } else if bridge.driverState != .current {
            let update = bridge.driverState == .outdated
            Notice(text: driverError ?? (update ? "This version comes with a newer audio driver."
                                                : "The Sendspin audio driver isn't installed."),
                   systemImage: "exclamationmark.triangle.fill") {
                Button(update ? "Update Driver…" : "Install Driver…") { installDriver() }
                    .disabled(bridge.isInstallingDriver)
            }
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

    private func installDriver() {
        driverError = nil
        Task {
            do {
                _ = try await bridge.installDriver()
            } catch {
                driverError = "Couldn't install the driver: \(error.localizedDescription)"
            }
        }
    }

    /// One row per speaker, after Apple Music's AirPlay list.
    private var speakers: some View {
        VStack(alignment: .leading, spacing: 0) {
            if bridge.players.isEmpty {
                Text("Looking for Sendspin speakers…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
            ForEach(bridge.players) { player in
                PlayerRow(player: player, bridge: bridge)
            }
        }
    }
}

/// Name, then the volume slider (selected and connected) or a status, then a checkbox.
/// There are no device icons: Sendspin doesn't say what kind of device a speaker is.
private struct PlayerRow: View {
    let player: BridgeController.Player
    let bridge: BridgeController
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            // Clicking the name toggles the speaker, as in Apple Music. The slider sits
            // outside this area, so dragging it never toggles.
            HStack(spacing: 6) {
                Text(player.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // The format this speaker receives, while hovering a streaming row.
                if hovering, let format = formatLabel {
                    Text(format)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .onTapGesture { bridge.setSelected(player.instanceName, !player.isSelected) }

            trailing

            Toggle(player.name, isOn: Binding(get: { player.isSelected },
                                              set: { bridge.setSelected(player.instanceName, $0) }))
                .toggleStyle(RoundedCheckboxStyle(name: player.name))
                .labelsHidden()
        }
        .frame(height: 30)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var trailing: some View {
        if player.isSelected, let status = player.status, status.connection == .connected {
            if status.canSetVolume, let volume = status.volume {
                Slider(value: Binding(get: { Double(volume) },
                                      set: { bridge.setPlayerVolume(player.instanceName, Int($0.rounded())) }),
                       in: 0...100)
                    .controlSize(.small)
                    // Neutral like Apple Music's AirPlay sliders, not the accent colour.
                    .tint(.primary.opacity(0.8))
                    .frame(width: 90)
                    .accessibilityLabel("\(player.name) volume")
            }
        } else if let statusText {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .help(statusHelp)
        }
    }

    private var formatLabel: String? {
        guard let format = player.status?.streamFormat else { return nil }
        return BridgeController.StreamFormat(sampleRate: format.sampleRate, bitDepth: format.bitDepth).label
    }

    /// Only for what needs attention; a connected speaker shows its slider instead.
    private var statusText: String? {
        guard player.isDiscovered else { return "Offline" }
        guard player.isSelected else { return nil }
        switch player.status?.connection {
        case .connected: return nil
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

/// Apple Music's AirPlay checkbox: a rounded grey square, with a white check when on.
private struct RoundedCheckboxStyle: ToggleStyle {
    /// For VoiceOver: the style draws no label.
    let name: String

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(.secondary.opacity(configuration.isOn ? 0.55 : 0.22))
                .frame(width: 20, height: 20)
                .overlay {
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityValue(configuration.isOn ? "on" : "off")
        .accessibilityAddTraits(configuration.isOn ? [.isButton, .isSelected] : .isButton)
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
