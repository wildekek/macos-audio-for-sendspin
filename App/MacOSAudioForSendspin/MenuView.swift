import AppKit
import SendspinServerKit
import SwiftUI

struct MenuView: View {
    @Bindable var bridge: BridgeController
    @Environment(\.openSettings) private var openSettings
    @State private var driverError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            warnings
            if bridge.driverInstalled {
                destinations
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

    /// One list of where the Mac's sound can go, as in the macOS Sound menu: Sendspin speakers
    /// (with the speakers within), Music Assistant once it found this Mac, and the Mac's own
    /// output. What belongs to a destination hangs underneath it.
    private var destinations: some View {
        let onSpeakers = bridge.isMacOutput && bridge.destination == .speakers
        // Sendspin speakers shows once there's a speaker (found or ticked), or while it's chosen.
        let showsSpeakers = !bridge.players.isEmpty || onSpeakers || bridge.waitsForSpeaker
        return VStack(alignment: .leading, spacing: 2) {
            if !showsSpeakers && !bridge.offersMusicAssistant {
                LookingRow()
            }
            if showsSpeakers {
                DestinationRow(icon: .symbol("hifispeaker.fill"), title: "Sendspin speakers", chosen: onSpeakers,
                               state: onSpeakers ? speakersState : nil,
                               action: { bridge.chooseSpeakers() }) {
                    // No group slider: the Mac's volume is the group's volume.
                    if !onSpeakers, let names = bridge.speakersSummary {
                        Text(names)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            if onSpeakers || bridge.waitsForSpeaker {
                speakers
            }
            if bridge.offersMusicAssistant {
                MusicAssistantRows(bridge: bridge)
            }
            DestinationRow(icon: .symbol("laptopcomputer"), title: bridge.macOutputName, chosen: !bridge.isMacOutput,
                           action: { bridge.chooseMac() }) {
                EmptyView()
            }
        }
    }

    /// Idle means connected, with nothing playing; with no speaker connected there's no state,
    /// unless the ticked ones are all gone.
    private var speakersState: DestinationState? {
        if bridge.selectedPlayersUnavailable { return .unavailable }
        guard bridge.hasConnectedPlayers else { return nil }
        return bridge.isStreaming ? .streaming : .idle
    }

    /// The speakers within Sendspin speakers, after Apple Music's AirPlay list.
    private var speakers: some View {
        VStack(alignment: .leading, spacing: 0) {
            if bridge.players.isEmpty {
                Text("Looking for Sendspin speakers…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else if !bridge.hasSelectedPlayers {
                Text("Tick a speaker to play on it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
            ForEach(bridge.players) { player in
                PlayerRow(player: player, bridge: bridge)
            }
        }
        .padding(.leading, destinationIndent)
        .padding(.bottom, 6)
    }
}

/// Where what hangs under a destination starts: past its icon.
private let destinationIndent: CGFloat = 36

/// Before any speaker or Music Assistant is found: what the app is looking for, and where to
/// read which speakers work with it.
private struct LookingRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 26, height: 26)
                .background(Color.secondary.opacity(0.2), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text("Looking for speakers…")
                    .fontWeight(.semibold)
                Text("Sendspin speakers and Music Assistant on your network show up here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                WebLink(title: "Which speakers work with this app?",
                        url: URL(string: "https://www.sendspin-audio.com/#speakers")!)
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 6)
    }
}

/// Whether a chosen destination gets the Mac's audio, on the right of its row.
private enum DestinationState {
    case streaming, idle, unavailable

    var text: String {
        switch self {
        case .streaming: "Streaming"
        case .idle: "Idle"
        case .unavailable: "Unavailable"
        }
    }
}

/// A link that looks like one: underlined, with the pointing hand, while hovered.
private struct WebLink: View {
    let title: String
    let url: URL
    @State private var hovering = false

    var body: some View {
        Link(destination: url) {
            Text(title).underline(hovering)
        }
        .font(.callout)
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

/// A destination's icon: an SF Symbol, or a template image from the asset catalog (Music
/// Assistant's own mark), drawn the same way.
private enum DestinationIcon {
    case symbol(String)
    case asset(String)

    @ViewBuilder var image: some View {
        switch self {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 12, weight: .medium))
        case .asset(let name):
            Image(name)
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
        }
    }
}

/// A destination: a round icon, blue when chosen, its name, and on the right its state
/// while chosen or whatever else it shows.
private struct DestinationRow<Trailing: View>: View {
    let icon: DestinationIcon
    let title: String
    let chosen: Bool
    var state: DestinationState?
    let action: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            // The icon and name keep their size, and what's on the right gets the space that's
            // left, so a long list of speakers truncates instead of widening the menu.
            Button(action: action) {
                HStack(spacing: 10) {
                    icon.image
                        .foregroundStyle(chosen ? Color.white : Color.primary)
                        .frame(width: 26, height: 26)
                        .background(chosen ? Color.accentColor : Color.secondary.opacity(0.2), in: Circle())
                    Text(title)
                        .fontWeight(chosen ? .semibold : .regular)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityAddTraits(chosen ? .isSelected : [])
            HStack(spacing: 10) {
                if let state {
                    HStack(spacing: 4) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(state == .streaming ? Color.green : Color.secondary)
                        Text(state.text)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                }
                trailing
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: 38)
        // The whole row chooses, not only the icon and name.
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

/// Music Assistant as a destination. Until it's paired the whole row copies the pairing
/// token, and choosing it would only silence the Mac; once paired, choosing it hands the
/// Mac's audio to Music Assistant, which picks the speakers and the volume.
private struct MusicAssistantRows: View {
    let bridge: BridgeController
    @State private var copied = false
    /// Every copy, so each click shows: copying again is the way out of a lost clipboard.
    @State private var copies = 0

    var body: some View {
        let status = bridge.sourceStatus
        let needsPairing = status.connected && !status.paired
        let chosen = bridge.isMacOutput && bridge.destination == .musicAssistant && !needsPairing
        VStack(alignment: .leading, spacing: 2) {
            DestinationRow(icon: .asset("MusicAssistantIcon"), title: "Music Assistant", chosen: chosen,
                           state: chosen ? (!status.connected ? .unavailable : status.streaming ? .streaming : .idle) : nil,
                           action: { needsPairing ? copyToken() : bridge.chooseMusicAssistant() }) {
                if needsPairing {
                    Pill(text: copied ? "Copied" : "Copy Token", checked: copied, presses: copies)
                        .onTapGesture(perform: copyToken)
                } else if !chosen {
                    Text(status.connected ? "Ready" : "Unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            .accessibilityHint(needsPairing ? "Copies the pairing token" : "")

            if needsPairing {
                // Where players waiting for setup are listed.
                caption("Then pair this Mac in ", musicAssistantLinkingTo: "/settings/players?status=needs_setup", ".")
                    .padding(.leading, destinationIndent)
                    .padding(.bottom, 6)
            } else if chosen && status.connected && !status.streaming {
                // Where its sources are chosen.
                caption("Select \(bridge.macName) as an input source in ", musicAssistantLinkingTo: "/browse",
                        " to start playing.")
                    .padding(.leading, destinationIndent)
                    .padding(.bottom, 6)
            } else if chosen {
                caption(!status.connected ? "It reconnects by itself when it's back on the network."
                        : "Choose speakers, groups and volume in Music Assistant.")
                    .padding(.leading, destinationIndent)
                    .padding(.bottom, 6)
            }
        }
    }

    /// A caption with "Music Assistant" in it, linking to that page of its web interface when
    /// its address is known. Built as text, not Markdown: the Mac's name may hold * or [.
    private func caption(_ before: String, musicAssistantLinkingTo route: String, _ after: String) -> some View {
        var name = AttributedString("Music Assistant")
        name.link = bridge.musicAssistantPage(route)
        return caption(AttributedString(before) + name + AttributedString(after))
    }

    private func caption(_ text: String) -> some View {
        caption(AttributedString(text))
    }

    private func caption(_ text: AttributedString) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copyToken() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bridge.pairingToken, forType: .string)
        copied = true
        copies += 1
    }
}

/// The small grey label at the end of a row: "Copy Token", then "✓ Copied". It dips and
/// springs back on each press, and the checkmark bounces, also when it already says Copied.
private struct Pill: View {
    let text: String
    let checked: Bool
    /// Changes with each press.
    var presses = 0

    var body: some View {
        HStack(spacing: 4) {
            if checked {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .symbolEffect(.bounce, value: presses)
            }
            Text(text)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.2), in: RoundedRectangle(cornerRadius: 5))
        .fixedSize()
        .keyframeAnimator(initialValue: 1.0, trigger: presses) { content, scale in
            content.scaleEffect(scale)
        } keyframes: { _ in
            CubicKeyframe(0.88, duration: 0.07)
            SpringKeyframe(1.0, duration: 0.25, spring: .snappy)
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
            // Clicking the name plays on this speaker only, as AirPlay does; the checkbox adds
            // or removes it. The slider sits outside this area, so dragging it never selects.
            HStack(spacing: 6) {
                // While hovering the name, the format this speaker receives takes its place.
                // It's drawn over the name, so nothing moves: the row has no room for both.
                let format = hovering ? formatLabel : nil
                Text(player.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .opacity(format == nil ? 1 : 0)
                    .overlay(alignment: .leading) {
                        if let format {
                            Text(format)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .onHover { hovering = $0 }
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                bridge.selectOnly(player.instanceName)
                bridge.chooseSpeakers()
            }

            trailing

            Toggle(player.name, isOn: Binding(get: { player.isSelected },
                                              set: { isOn in
                                                  bridge.setSelected(player.instanceName, isOn)
                                                  if isOn { bridge.chooseSpeakers() }
                                              }))
                .toggleStyle(RoundedCheckboxStyle(name: player.name))
                .labelsHidden()
        }
        .frame(height: 30)
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
        // Only a ticked speaker stays listed while it's gone: it plays again once it's back.
        guard player.isDiscovered else { return "Unavailable" }
        guard player.isSelected || player.status?.connection == .left else { return nil }
        switch player.status?.connection {
        case .connected: return nil
        case .taken, .left: return "In use elsewhere"
        case .pairingRequired: return "Needs pairing"
        case .notApproved: return "Identity changed"
        case .unavailable: return "Unavailable"
        case .disconnected: return "Disconnected"
        case .failed: return "Can't connect"
        case .connecting, .awaitingApproval, nil: return "Connecting…"
        }
    }

    private var statusHelp: String {
        if !player.isDiscovered || player.status?.connection == .unavailable {
            return "This speaker can't be reached. It plays again by itself once it's back on the network."
        }
        return switch player.status?.connection {
        case .disconnected:
            "This speaker disconnected from this Mac. Untick and tick it to connect again."
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
