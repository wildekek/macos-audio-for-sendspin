import AppKit
import SendspinMenuUI
import SendspinServerKit
import SwiftUI

/// The menu bar menu. What it shows in each situation, and what every state means, is written
/// down in docs/menu-states.md: change that along with the states here.
struct MenuView: View {
    @Bindable var bridge: BridgeController
    @Environment(\.openSettings) private var openSettings
    @State private var driverError: String?
    @State private var shortcuts: Any?

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
                Spacer()
                Button(action: showSettings) {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                .accessibilityLabel("Settings")
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 360)
        .onAppear(perform: watchShortcuts)
        .onDisappear {
            if let shortcuts { NSEvent.removeMonitor(shortcuts) }
            shortcuts = nil
        }
    }

    private func showSettings() {
        // A menu bar app isn't active, so the window would open behind other apps.
        NSApp.activate()
        openSettings()
    }

    /// ⌘Q and ⌘, while the menu is open. A button's keyboard shortcut doesn't fire in a menu bar
    /// extra's window, so the menu watches the keys itself.
    private func watchShortcuts() {
        guard shortcuts == nil else { return }
        shortcuts = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return event }
            switch event.charactersIgnoringModifiers {
            case "q":
                MainActor.assumeIsolated { NSApp.terminate(nil) }
                return nil
            case ",":
                MainActor.assumeIsolated { showSettings() }
                return nil
            default:
                return event
            }
        }
    }

    /// Whether Sendspin is in use, as the checks show a speaker (`SpeakerMenu.dot`): blue while it
    /// plays, grey while it's the Mac's output but nothing goes out, an empty ring while the Mac
    /// plays without it. Choosing where to play sets it; there's nothing to switch.
    private var header: some View {
        let dot = bridge.dot
        let label = switch dot {
        case .plays: "Playing: the Mac's sound goes through Sendspin"
        case .inUse: "In use: the Mac plays through Sendspin, but nothing goes out now"
        case .notInUse: "Not in use: the Mac plays directly"
        }
        let fill: Color = switch dot {
        case .plays: .accentColor
        // The grey of a grey check: in, but not doing anything.
        case .inUse: .secondary.opacity(0.5)
        case .notInUse: .clear
        }
        return HStack {
            Text("Sendspin")
                .fontWeight(.semibold)
            Spacer()
            Circle()
                .fill(fill)
                .overlay {
                    if dot == .notInUse { Circle().strokeBorder(Color.secondary.opacity(0.7), lineWidth: 1.5) }
                }
                .frame(width: 10, height: 10)
                // While it plays, a tight, soft halo: 1 pt wider than the dot, blurred.
                .background {
                    if dot == .plays {
                        Circle()
                            .fill(Color.accentColor.opacity(0.45))
                            .frame(width: 12, height: 12)
                            .blur(radius: 1.5)
                    }
                }
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
            OutputRow(name: server,
                      glyph: bridge.sourceServerIsMusicAssistant ? .asset("MusicAssistantIcon") : .symbol("server.rack"),
                      row: row, statusHelp: "\(server) can't be reached. It connects to this Mac again by itself.",
                      onName: action)
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

/// A speaker or the Mac's own output. How it shows its state is `SpeakerMenu`'s; `OutputRow`
/// draws it (as for the server's row), and this says what clicking does. The Mac's own output
/// has its icon from the Sound menu (laptop, AirPods); Sendspin doesn't say what kind of device
/// a speaker is, so they all have one.
private struct PlayerRow: View {
    let player: BridgeController.Player
    let bridge: BridgeController

    var body: some View {
        let row = bridge.row(for: player)
        OutputRow(name: player.name, glyph: .symbol(player.isLocal ? bridge.localIcon : "hifispeaker.fill"),
                  row: row, volume: volume, format: formatLabel, statusHelp: statusHelp,
                  onName: { bridge.perform(.playOnly(player.instanceName)) },
                  onCheck: {
                      switch row.click {
                      case .add: bridge.perform(.add(player.instanceName))
                      case .remove: bridge.perform(.remove(player.instanceName))
                      case nil: break
                      }
                  })
    }

    /// The slider, while it plays and its volume can be set.
    private var volume: Binding<Double>? {
        guard player.isActive, let status = player.status, status.connection == .connected,
              status.canSetVolume, let volume = status.volume else { return nil }
        return Binding(get: { Double(volume) },
                       set: { bridge.setPlayerVolume(player.instanceName, Int($0.rounded())) })
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
