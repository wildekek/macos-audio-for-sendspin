import AppKit
import SendspinServerKit
import SwiftUI

/// The menu bar menu. What it shows in each situation, and what every state means, is written
/// down in docs/menu-states.md: change that along with the states here.
struct MenuView: View {
    @Bindable var bridge: BridgeController
    @Environment(\.openSettings) private var openSettings
    @State private var driverError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            warnings
            if bridge.driverInstalled {
                Divider()
                outputs
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

    /// Whether Sendspin is in use: a dot, filled while the Mac plays through Sendspin, an empty
    /// ring while it plays directly. Choosing where to play sets it; there's nothing to switch.
    private var header: some View {
        let label = bridge.isMacOutput ? "In use: the Mac plays through Sendspin" : "Not in use: the Mac plays directly"
        return HStack {
            Text("Sendspin")
                .fontWeight(.semibold)
            Spacer()
            Circle()
                .fill(bridge.isMacOutput ? Color.accentColor : Color.clear)
                .overlay {
                    if !bridge.isMacOutput { Circle().strokeBorder(Color.secondary.opacity(0.7), lineWidth: 1.5) }
                }
                .frame(width: 10, height: 10)
                .padding(.trailing, 6)
                .help(label)
                .accessibilityElement()
                .accessibilityLabel(label)
        }
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

    /// Where the Mac's sound can go: its own speakers and the Sendspin speakers, which play
    /// together in sync, then below a divider Music Assistant, which plays on what it chooses
    /// and doesn't group with them.
    private var outputs: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(bridge.players) { player in
                PlayerRow(player: player, bridge: bridge)
            }
            if bridge.speakers.isEmpty && !bridge.offersMusicAssistant {
                LookingRow()
            }
            if bridge.offersMusicAssistant {
                Divider()
                    .padding(.vertical, 4)
                MusicAssistantRows(bridge: bridge)
            }
        }
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

/// Why a destination can't play, on the right of its row. Whether it plays shows on the menu
/// bar icon, not in the rows: the Mac's own output couldn't tell, and a working destination
/// needs no word.
private func reason(_ text: String) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize()
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

/// A destination: a round icon, blue when chosen, its name, and on the right whatever it
/// shows: why it can't play, the speakers in it, or the pairing token.
private struct DestinationRow<Trailing: View>: View {
    let icon: DestinationIcon
    let title: String
    let chosen: Bool
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
            trailing
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: 38)
        // The whole row chooses, not only the icon and name.
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

/// A server this Mac is a source for, such as Music Assistant, as a destination. Until it's
/// paired, the row opens the server's setup page (when known), and choosing it would only
/// silence the Mac; once paired, choosing it hands the Mac's audio to the server, which picks
/// the speakers and the volume. Pairing is by a code this Mac shows, here and in a window:
/// servers support every method, so the code always works. The pairing token is for automated
/// pairing between systems, not for people (the implementation guide), so it's in Settings.
/// Music Assistant only adds its logo and links to its own pages.
private struct MusicAssistantRows: View {
    let bridge: BridgeController

    var body: some View {
        let status = bridge.sourceStatus
        let needsPairing = status.connected && !status.paired
        let chosen = bridge.isMacOutput && bridge.destination == .musicAssistant && !needsPairing
        let server = bridge.sourceServerName
        VStack(alignment: .leading, spacing: 2) {
            DestinationRow(icon: bridge.sourceServerIsMusicAssistant ? .asset("MusicAssistantIcon") : .symbol("server.rack"),
                           title: server, chosen: chosen,
                           action: { needsPairing ? openSetupPage() : bridge.chooseMusicAssistant() }) {
                if !status.connected {
                    reason("Unavailable")
                }
            }
            .accessibilityHint(needsPairing ? "Opens \(server) to pair this Mac" : "")

            if let code = status.pairingCode {
                // The server is pairing by a code shown here (and in its window).
                caption("Enter \(code.prefix(3))-\(code.suffix(3)) in ", serverLinkingTo: Self.setupPage, ".")
                    .padding(.leading, destinationIndent)
                    .padding(.bottom, 6)
            } else if needsPairing {
                // Pairing starts on the server; the code it asks for shows up here.
                caption("Pair this Mac in ", serverLinkingTo: Self.setupPage, ", then enter the code that appears here.")
                    .padding(.leading, destinationIndent)
                    .padding(.bottom, 6)
            } else if chosen && status.connected && !status.streaming {
                // Where its sources are chosen.
                caption("Select \(bridge.macName) as an input source in ", serverLinkingTo: "/browse", " to start playing.")
                    .padding(.leading, destinationIndent)
                    .padding(.bottom, 6)
            } else if chosen {
                caption(!status.connected ? "It reconnects by itself when it's back on the network."
                        : "Choose speakers, groups and volume in \(server).")
                    .padding(.leading, destinationIndent)
                    .padding(.bottom, 6)
            }
        }
    }

    /// Music Assistant's list of players waiting for setup, where pairing happens.
    private static let setupPage = "/settings/players?status=needs_setup"

    /// A caption with the server's name in it, linking to that page of Music Assistant's web
    /// interface when the server is Music Assistant and its address is known. Built as text,
    /// not Markdown: the Mac's name may hold * or [.
    private func caption(_ before: String, serverLinkingTo route: String, _ after: String) -> some View {
        var name = AttributedString(bridge.sourceServerName)
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

    private func openSetupPage() {
        if let url = bridge.musicAssistantPage(Self.setupPage) { NSWorkspace.shared.open(url) }
    }
}

/// A speaker, as in Apple's AirPlay picker: its device icon, its name, the volume slider while
/// it plays or a status when something needs attention, then a round check. The check is the
/// group: filled while the speaker is in it (playing, connecting or gone), an empty ring when
/// it isn't; clicking it adds or removes the speaker. Clicking the name plays there only, as in
/// the Sound menu. Every output is groupable or not (an AirPlay output and Music Assistant
/// aren't), and one rule decides the check: it shows when the row is groupable and what plays
/// now is too. While something that isn't groupable plays, nothing can join it, so there are
/// no checks and the names are the way in. The Mac's own output has
/// its icon from the Sound menu (laptop, AirPods); Sendspin doesn't say what kind of device a
/// speaker is, so they all have one.
private struct PlayerRow: View {
    let player: BridgeController.Player
    let bridge: BridgeController
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: choose) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primary)
                        .frame(width: 26, height: 26)
                        .background(Color.secondary.opacity(0.2), in: Circle())
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
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play on \(player.name) only")

            trailing

            if player.isGroupable && bridge.playsGroupable {
                Button(action: checkClicked) {
                    check
                        // The row's full height and some room before it: easy to hit.
                        .frame(width: 30, height: 38, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(checkLabel)
                .accessibilityLabel(checkLabel)
                .accessibilityAddTraits(player.isSelected ? .isSelected : [])
            }
        }
        .frame(height: 38)
    }

    // MARK: The check

    /// It can leave the group: not when it's all that plays.
    private var canLeave: Bool { player.isSelected && (bridge.groupCount > 1 || !player.isActive) }

    private var checkLabel: String {
        if player.isSelected { return canLeave ? "Remove \(player.name)" : "\(player.name) plays" }
        return "Add \(player.name)"
    }

    private func checkClicked() {
        if player.isSelected {
            if canLeave { bridge.setTicked(player.instanceName, false) }
        } else {
            bridge.setTicked(player.instanceName, true)
        }
    }

    private var check: some View {
        ZStack {
            if player.isSelected {
                Circle().fill(Color.accentColor)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1.5)
            }
        }
        .frame(width: 22, height: 22)
    }

    private var icon: String {
        player.isLocal ? bridge.localIcon : "hifispeaker.fill"
    }

    // MARK: Beside the name

    @ViewBuilder private var trailing: some View {
        if player.isActive, let status = player.status, status.connection == .connected {
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
                // "Identity changed" is what asks for the click, so the status takes one too.
                .contentShape(Rectangle())
                .onTapGesture(perform: choose)
        }
    }

    private func choose() {
        bridge.playOnly(player.instanceName)
    }

    private var formatLabel: String? {
        guard let format = player.status?.streamFormat else { return nil }
        let rateAndDepth = BridgeController.StreamFormat(sampleRate: format.sampleRate, bitDepth: format.bitDepth).label
        return "\(format.codec.uppercased()) · \(rateAndDepth)"
    }

    /// Only for what needs attention; a playing speaker shows its slider instead.
    private var statusText: String? {
        // Only a speaker in the group stays listed while it's gone: it plays again once it's back.
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
            return player.isLocal ? "This Mac has no speakers of its own."
                : "This speaker can't be reached. It plays again by itself once it's back on the network."
        }
        return switch player.status?.connection {
        case .disconnected:
            "This speaker disconnected from this Mac. Remove it and add it again to connect again."
        case .left:
            "This speaker is playing something else. Add it to play your Mac's sound on it again."
        case .pairingRequired:
            "This speaker only plays for paired servers, and pairing isn't supported yet."
        case .notApproved:
            "This speaker presents a different identity than the one you allowed. "
                + "If you trust it, click its name."
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
