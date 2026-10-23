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
        .frame(width: 360)
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
    /// together in sync, then below a divider the server (Music Assistant or another), which
    /// plays on what it chooses and doesn't group with them.
    private var outputs: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(bridge.players) { player in
                PlayerRow(player: player, bridge: bridge)
            }
            if bridge.speakers.isEmpty && !bridge.offersServer {
                LookingRow()
            }
            if bridge.offersServer {
                Divider()
                    .padding(.vertical, 4)
                ServerRows(bridge: bridge)
            }
        }
    }
}

/// A darker orange than the system's in light mode, so the warning stands out on the light
/// menu; the system's own in dark mode.
private let warningOrange = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 1, green: 0.62, blue: 0.04, alpha: 1)
        : NSColor(srgbRed: 0.76, green: 0.37, blue: 0, alpha: 1)
})

/// Where what hangs under a destination starts: past its icon.
private let destinationIndent: CGFloat = 36

/// Before any speaker or server is found: what the app is looking for, and where to
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

/// An output's round icon, for speakers and servers alike: blue while it plays where there's
/// no check to say it (`SpeakerMenu.Row.iconIsBlue`), as in the Sound menu.
private struct OutputIcon: View {
    let icon: DestinationIcon
    let isBlue: Bool

    var body: some View {
        icon.image
            .foregroundStyle(isBlue ? Color.white : Color.primary)
            .frame(width: 26, height: 26)
            .background(isBlue ? Color.accentColor : Color.secondary.opacity(0.2), in: Circle())
    }
}

/// Why an output can't play, on the right of its row, for speakers and servers alike: with a
/// warning triangle when something is wrong (`SpeakerMenu.Row.showsWarning`).
private struct StatusLabel: View {
    let text: String
    let showsWarning: Bool
    var help = ""

    var body: some View {
        HStack(spacing: 4) {
            if showsWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(warningOrange)
            }
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .fixedSize()
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(showsWarning ? "Warning: \(text)" : text)
    }
}

/// A Sendspin server this Mac is a source for, such as Music Assistant, as a destination. Until
/// it's paired, the row opens the server's setup page (when known), and choosing it would only
/// silence the Mac; once paired, choosing it hands the Mac's audio to the server, which picks
/// the speakers and the volume. Pairing is by a code this Mac shows, here and in a window:
/// servers support every method, so the code always works. The pairing token is for automated
/// pairing between systems, not for people (the implementation guide), so it's in Settings.
/// Music Assistant only adds its logo and links to its own pages.
private struct ServerRows: View {
    let bridge: BridgeController

    var body: some View {
        let status = bridge.sourceStatus
        let needsPairing = status.connected && !status.paired
        let chosen = bridge.serverChosen
        let server = bridge.sourceServerName
        let row = bridge.serverRow
        let action = { needsPairing ? openSetupPage() : bridge.chooseServer() }
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Button(action: action) {
                    HStack(spacing: 10) {
                        OutputIcon(icon: bridge.sourceServerIsMusicAssistant ? .asset("MusicAssistantIcon")
                                       : .symbol("server.rack"),
                                   isBlue: row.iconIsBlue)
                        Text(server)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? .isSelected : [])
                .accessibilityHint(needsPairing ? "Opens \(server) to pair this Mac" : "")
                if let text = row.status {
                    StatusLabel(text: text, showsWarning: row.showsWarning,
                                help: "\(server) can't be reached. It connects to this Mac again by itself.")
                }
            }
            .frame(height: 38)

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
/// the Sound menu. Every output is groupable or not (an AirPlay output and a server
/// aren't), and one rule decides the check: it shows when the row is groupable and what plays
/// now is too. While something that isn't groupable plays, nothing can join it, so there are
/// no checks and the names are the way in. The Mac's own output has
/// its icon from the Sound menu (laptop, AirPods); Sendspin doesn't say what kind of device a
/// speaker is, so they all have one. One indicator per row: the check where it's groupable, and
/// where it isn't, a blue icon while it plays, as in the Sound menu and the server's row.
private struct PlayerRow: View {
    let player: BridgeController.Player
    let bridge: BridgeController
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: choose) {
                HStack(spacing: 10) {
                    OutputIcon(icon: .symbol(icon), isBlue: row.iconIsBlue)
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

            if row.check != .none {
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

    /// How the row shows its state: `SpeakerMenu` decides.
    private var row: SpeakerMenu.Row { bridge.row(for: player) }

    // MARK: The check

    private var checkLabel: String {
        switch (row.check, row.click) {
        case (.spinner, _): "Connecting to \(player.name); click to remove it"
        case (.empty, _): "Add \(player.name)"
        case (_, .remove): "Remove \(player.name)"
        default: "\(player.name) plays"
        }
    }

    private func checkClicked() {
        switch row.click {
        case .add: bridge.perform(.add(player.instanceName))
        case .remove: bridge.perform(.remove(player.instanceName))
        case nil: break
        }
    }

    private var check: some View {
        ZStack {
            switch row.check {
            case .spinner:
                ProgressView()
                    .controlSize(.small)
            case .filled, .grey:
                Circle().fill(row.check == .grey ? Color.secondary.opacity(0.5) : Color.accentColor)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            case .empty, .none:
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
                    .frame(width: 80)
                    .accessibilityLabel("\(player.name) volume")
            }
        } else if let statusText = row.status {
            StatusLabel(text: statusText, showsWarning: row.showsWarning, help: statusHelp)
            // "Identity changed" is what asks for the click, so the status takes one too.
            .contentShape(Rectangle())
            .onTapGesture(perform: choose)
        }
    }

    private func choose() {
        bridge.perform(.playOnly(player.instanceName))
    }

    private var formatLabel: String? {
        guard let format = player.status?.streamFormat else { return nil }
        let rateAndDepth = BridgeController.StreamFormat(sampleRate: format.sampleRate, bitDepth: format.bitDepth).label
        return "\(format.codec.uppercased()) · \(rateAndDepth)"
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
