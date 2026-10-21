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
                if bridge.offersMusicAssistant {
                    HStack(spacing: 16) {
                        DestinationTab(title: "Speakers", destination: .speakers, bridge: bridge)
                        DestinationTab(title: "Music Assistant", destination: .musicAssistant, bridge: bridge,
                                       nudge: bridge.sourceStatus.connected && !bridge.sourceStatus.paired)
                    }
                }
                if bridge.destination == .speakers {
                    speakers
                } else {
                    MusicAssistantPanel(bridge: bridge)
                }
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

    /// Where the Mac's sound plays, and a quiet link to the other output: the choice is
    /// between two outputs, not on or off.
    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Centred, not on the baseline: a caption on a headline's baseline looks low.
            HStack(alignment: .center) {
                Text("Playing on \(bridge.isMacOutput ? "Sendspin" : bridge.currentOutputName ?? "this Mac")")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                // With somewhere to play: green while audio goes out, grey while silent.
                if bridge.hasDestination {
                    let streaming = bridge.isPlayingOut
                    HStack(spacing: 4) {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(streaming ? Color.green : Color.secondary)
                            .font(.system(size: 6))
                        Text(streaming ? "Streaming" : "Idle")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            if let action = switchAction {
                Button(action.title) { Task { await bridge.setMacOutput(action.toSendspin) } }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .disabled(bridge.isSwitchingOutput)
            }
        }
    }

    /// Switching to Sendspin needs a connected speaker or Music Assistant, or the Mac would
    /// go silent; switching back is always offered.
    private var switchAction: (title: String, toSendspin: Bool)? {
        if bridge.isMacOutput {
            return bridge.returnOutputName.map { ("Use \($0)", false) }
        }
        guard bridge.driverInstalled, bridge.hasDestination else { return nil }
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
        } else if bridge.localNetworkDenied {
            Notice(text: "Allow Local Network access so the app can find your speakers.",
                   systemImage: "network.slash") {
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
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

/// A light text tab: the active one semibold and underlined, the other secondary. A `nudge`
/// dot points at an inactive tab that wants attention (Music Assistant waiting to pair).
private struct DestinationTab: View {
    let title: String
    let destination: BridgeController.Destination
    let bridge: BridgeController
    var nudge = false

    var body: some View {
        let active = bridge.destination == destination
        let showsNudge = nudge && !active
        Button { bridge.setDestination(destination) } label: {
            HStack(spacing: 5) {
                Text(title)
                if showsNudge {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                }
            }
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Color.primary : Color.secondary)
                .padding(.bottom, 3)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(active ? Color.primary : Color.clear)
                        .frame(height: 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showsNudge ? "\(title), waiting to pair" : title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Music Assistant as the destination: it plays the Mac's audio wherever it chooses, at its
/// own volume. Until the connected server is paired, this offers the pairing token; finding
/// and playing the input is Music Assistant's part.
private struct MusicAssistantPanel: View {
    let bridge: BridgeController
    @State private var copied = false

    var body: some View {
        let status = bridge.sourceStatus
        VStack(alignment: .leading, spacing: 6) {
            if status.connected && !status.paired {
                HStack(spacing: 10) {
                    Text("Music Assistant found this Mac")
                    Spacer(minLength: 8)
                    if copied {
                        Text("Copied · Open Music Assistant")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    } else {
                        Button("Copy Token", action: copyToken)
                            .controlSize(.small)
                    }
                }
                .frame(height: 30)
                Text("Copy the token, then pair this Mac in Music Assistant.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(status.streaming ? Color.green : Color.secondary)
                    Text(!status.connected ? "Music Assistant isn't connected"
                         : status.streaming ? "Music Assistant is playing the Mac's audio"
                         : "Ready for Music Assistant")
                }
                .frame(height: 30)
                Text(status.connected && !status.streaming
                     ? "Select \(bridge.macName) as an input source in Music Assistant to start playing."
                     : "Choose speakers, groups and volume in Music Assistant.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func copyToken() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bridge.pairingToken, forType: .string)
        copied = true
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
            // Clicking the name plays on this speaker only, as AirPlay does; the checkbox adds
            // or removes it. The slider sits outside this area, so dragging it never selects.
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
            .onTapGesture { bridge.selectOnly(player.instanceName) }

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
        let rateAndDepth = BridgeController.StreamFormat(sampleRate: format.sampleRate, bitDepth: format.bitDepth).label
        return "\(format.codec.uppercased()) · \(rateAndDepth)"
    }

    /// Only for what needs attention; a connected speaker shows its slider instead.
    private var statusText: String? {
        guard player.isDiscovered else { return "Offline" }
        guard player.isSelected || player.status?.connection == .left else { return nil }
        switch player.status?.connection {
        case .connected: return nil
        case .taken, .left: return "In use elsewhere"
        case .pairingRequired: return "Needs pairing"
        case .notApproved: return "Identity changed"
        case .disconnected: return "Disconnected"
        case .failed: return "Can't connect"
        case .connecting, .awaitingApproval, nil: return "Connecting…"
        }
    }

    private var statusHelp: String {
        switch player.status?.connection {
        case .left:
            "This speaker is playing something else. Tick it to play your Mac's sound on it again."
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
