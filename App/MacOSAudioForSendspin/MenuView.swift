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
    @State private var window = MenuWindow()

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
        .background(MenuWindow.Reader(found: window))
        .onAppear(perform: watchShortcuts)
        .onDisappear {
            if let shortcuts { NSEvent.removeMonitor(shortcuts) }
            shortcuts = nil
        }
    }

    private func showSettings() {
        // A menu bar app isn't active, so the window would open behind other apps. macOS lets it
        // become active only while the click in the menu counts: before the menu closes.
        NSApp.activate()
        openSettings()
        // The menu stays open otherwise, in front of Settings: a menu bar extra's window floats.
        window.window?.close()
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
                MainActor.assumeIsolated {
                    // A key press doesn't count as a reason to come to the front, as a click
                    // does: macOS turns down `activate()` here, so this asks the old way.
                    NSApp.activate(ignoringOtherApps: true)
                    showSettings()
                }
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
        if bridge.driverNeedsRestart
            || (bridge.hasLookedForDevice && !bridge.driverInstalled && bridge.driverState != .notInstalled) {
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
            if bridge.showsSources {
                Divider()
                    .padding(.vertical, 4)
                SourceSection(bridge: bridge)
            }
        }
    }
}

/// What plays on the speakers: the Mac's own sound, or a Sendspin source (a turntable, a TV).
/// One at a time, so no checks: the one playing has the blue icon, as a server has, and its
/// name chooses it. An unpaired source asks once before it plays (roles/source/v1.md,
/// Unpaired access); one that needs pairing is paired under its row, as a speaker is. While a
/// server is chosen it picks what it plays: the sources show, dimmed, with the Mac's sound,
/// which goes to the server, still blue.
private struct SourceSection: View {
    let bridge: BridgeController

    var body: some View {
        let available = bridge.sourcesAvailable
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("Source")
                    .fontWeight(.semibold)
                if !available {
                    Text("· \(bridge.sourceServerName) picks what plays")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.bottom, 2)
            VStack(alignment: .leading, spacing: 2) {
                OutputRow(name: "This Mac", glyph: .symbol(bridge.macIcon),
                          row: SpeakerMenu.sourceRow(chosen: bridge.activeSource == nil, connection: .connected),
                          nameLabel: "Play this Mac's sound", onName: { bridge.chooseSource(nil) })
                ForEach(bridge.sources) { source in
                    SourceRow(source: source, bridge: bridge)
                }
            }
            .disabled(!available)
            .opacity(available ? 1 : 0.45)
        }
    }
}

private struct SourceRow: View {
    let source: BridgeController.Source
    let bridge: BridgeController

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            OutputRow(name: source.name, glyph: .symbol("cable.connector"),
                      row: SpeakerMenu.sourceRow(chosen: source.isChosen, connection: source.connection,
                                                 isDiscovered: source.isDiscovered),
                      statusHelp: statusHelp, nameLabel: "Play \(source.name)",
                      onName: { bridge.chooseSource(source.instanceName) })
            if bridge.sourceQuestion == source.instanceName {
                question
            } else if let phase = tokenPhase {
                TokenCaption(speaker: source.name, locations: bridge.pairMethods(for: source.instanceName)?.pairingPSK ?? [],
                             phase: phase, scanning: bridge.scanning == source.instanceName,
                             onScan: { bridge.startScanning(source.instanceName) }) { token in
                    bridge.pairWithToken(source.instanceName, token: token)
                }
            } else if let pairing = bridge.speakerPairing, pairing.name == source.instanceName {
                PairingCaption(pairing: pairing, speaker: source.name,
                               methods: bridge.pairMethods(for: source.instanceName), bridge: bridge)
            }
        }
    }

    /// Asked the first time it's chosen, unpaired: its sound reaches the speakers only once
    /// it's allowed, and a microphone is better paired.
    private var question: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Let \(source.name) send its audio to this Mac? Your speakers then play whatever it picks up. "
                 + "For a microphone, pair it instead.")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Don't Allow") { bridge.denySource(source.instanceName) }
                Button("Pair Instead") { bridge.pairSourceInstead(source.instanceName) }
                Button("Allow") { bridge.allowSource(source.instanceName) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.caption)
        .padding(.leading, destinationIndent)
        .padding(.bottom, 6)
    }

    private var tokenPhase: TokenCaption.Phase? {
        if let entry = bridge.tokenEntry, entry.name == source.instanceName { return .looking(again: entry.again) }
        guard let pairing = bridge.speakerPairing, pairing.name == source.instanceName,
              case .token = pairing.method else { return nil }
        return pairing.progress == .paired ? .paired : .pairing
    }

    private var statusHelp: String {
        switch source.connection {
        case .pairingRequired: "\(source.name) only plays for paired servers. Click its name to pair it."
        case .notRecognized: "\(source.name) no longer recognizes this Mac. Click its name to pair it again."
        default: source.isDiscovered ? "" : "\(source.name) can't be reached. It plays again by itself once it's back."
        }
    }
}


/// Where what hangs under a destination starts: past its icon.
let destinationIndent: CGFloat = 36

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

    /// While it's being paired, what's under the row says it all: no warning on it. Its check
    /// is grey, in the group but not playing yet, and unticking it cancels the pairing.
    private var row: SpeakerMenu.Row {
        var row = bridge.row(for: player)
        if bridge.speakerPairing?.name == player.instanceName || bridge.tokenEntry?.name == player.instanceName {
            row.status = nil
            row.showsWarning = false
            if row.check != .none {
                row.check = .grey
                row.click = .remove
            }
        }
        return row
    }

    var body: some View {
        let row = row
        VStack(alignment: .leading, spacing: 2) {
            OutputRow(name: player.name, glyph: .symbol(player.isLocal ? bridge.localIcon : "hifispeaker.fill"),
                      row: row, volume: volume, format: formatLabel, statusHelp: statusHelp,
                      onName: {
                          // A speaker that needs pairing: its name pairs it, by what it offers.
                          switch bridge.pairingWay(for: player) {
                          case .code(let method): bridge.startPairing(player.instanceName, method: method)
                          case .token: bridge.askForToken(player.instanceName)
                          case nil: bridge.perform(.playOnly(player.instanceName))
                          }
                      },
                      onCheck: {
                          switch row.click {
                          case .add: bridge.perform(.add(player.instanceName))
                          case .remove: bridge.perform(.remove(player.instanceName))
                          case nil: break
                          }
                      })
            if let phase = tokenPhase {
                // One view from looking to paired, so the camera stays on throughout.
                TokenCaption(speaker: player.name, locations: tokenLocations, phase: phase,
                             scanning: bridge.scanning == player.instanceName,
                             onScan: { bridge.startScanning(player.instanceName) }) { token in
                    bridge.pairWithToken(player.instanceName, token: token)
                }
            } else if let pairing = bridge.speakerPairing, pairing.name == player.instanceName {
                PairingCaption(pairing: pairing, speaker: player.name, methods: bridge.pairMethods(for: player.instanceName),
                               bridge: bridge)
            }
        }
    }

    private var tokenLocations: [PairMethods.Location] { bridge.pairMethods(for: player.instanceName)?.pairingPSK ?? [] }

    /// Where pairing by token stands: asked for, or with the camera, also while it pairs.
    private var tokenPhase: TokenCaption.Phase? {
        if let entry = bridge.tokenEntry, entry.name == player.instanceName { return .looking(again: entry.again) }
        guard let pairing = bridge.speakerPairing, pairing.name == player.instanceName,
              case .token = pairing.method else { return nil }
        return pairing.progress == .paired ? .paired : .pairing
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
            switch bridge.pairingWay(for: player) {
            case .code: "This speaker only plays for paired servers. Click its name to pair it."
            case .token: "This speaker only plays for paired servers. Click its name, then paste its pairing token."
            case nil: "This speaker only plays for paired servers, and offers no way to pair that this Mac knows."
            }
        case .notRecognized:
            "This speaker no longer recognizes this Mac: it was reset, or made room for another server. "
                + (bridge.pairingWay(for: player) == .token
                   ? "Click its name, then paste its pairing token, to pair it again."
                   : "Click its name to pair it again.")
        case .notApproved:
            "This speaker presents a different identity than the one you paired with or allowed. "
                + "If you trust it, click its name."
        default:
            ""
        }
    }
}

/// A pairing in progress, under the speaker's row: what it waits for, and the code entry.
struct PairingCaption: View {
    let pairing: BridgeController.SpeakerPairing
    let speaker: String
    let methods: PairMethods?
    let bridge: BridgeController
    /// Past the row's icon in the menu; Settings has none.
    var indent = destinationIndent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.caption)
        .padding(.leading, indent)
        .padding(.bottom, 6)
    }

    @ViewBuilder private var content: some View {
            switch pairing.progress {
            case .starting:
                busy("Pairing with \(speaker)…")
            case .checking:
                busy("Checking the code…")
            case .waiting(let message?):
                // From a device that isn't authenticated yet: plain text, said to be its.
                Text(verbatim: "\u{201C}\(message)\u{201D}")
                    .fixedSize(horizontal: false, vertical: true)
                Text("— \(speaker)")
                    .foregroundStyle(.secondary)
            case .waiting(nil):
                // A static code is only taken while the speaker's pairing window is open, which
                // a button on it usually opens (pairing.md, Pairing Window).
                busy(methodToRetry == .staticCode
                     ? "Waiting for \(speaker). Press its pairing button, if it has one."
                     : "Waiting for \(speaker)…")
            case .enteringCode(let prompt):
                Text(promptText(prompt))
                    .fixedSize(horizontal: false, vertical: true)
                CodeEntry(length: prompt.length) { bridge.submitPairingCode($0) }
            case .paired:
                Label("Paired", systemImage: "checkmark")
            case .failed(let text):
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") {
                    if let method = methodToRetry {
                        bridge.startPairing(pairing.name, method: method)
                    } else {
                        bridge.askForToken(pairing.name)
                    }
                }
                .controlSize(.small)
            }
    }

    private func busy(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(text)
        }
    }

    private var methodToRetry: PairingMethod? {
        if methods?.dynamicCode != nil { return .dynamicCode }
        if methods?.staticCode != nil { return .staticCode }
        return nil
    }

    private func promptText(_ prompt: PairingPrompt) -> String {
        switch prompt {
        case .staticCode(let again):
            let start = again ? "That code didn't match. " : ""
            let leaflet = methods?.staticCode?.contains(.leaflet) == true
            let onDevice = methods?.staticCode?.contains(.device) == true
            let place = leaflet && !onDevice ? "on the leaflet that came with \(speaker)"
                : onDevice && !leaflet ? "on \(speaker)" : "on \(speaker) or its leaflet"
            return start + "Enter the 8-digit code \(place):"
        case .dynamicCode(let again):
            return (again ? "That code didn't match. " : "") + "Enter the code that \(speaker) \(shows) now:"
        }
    }

    /// A speaker says its code when it has no display.
    private var shows: String {
        methods?.dynamicCode?.contains(.display) == false ? "says" : "shows"
    }
}

/// A speaker that offers no code: its pairing token. Printed, as a QR code, it's scanned in a
/// window of its own (`QRScanView`); it can also be pasted. Pairing starts as soon as there's a
/// token, as the code slots start once full. Pasted tokens are read leniently (whitespace,
/// case, the `SP:` prefix), as the spec asks; anything else reads as a token that didn't match.
struct TokenCaption: View {
    enum Phase: Equatable {
        /// `again`: the last token didn't match, as with a wrong code.
        case looking(again: Bool)
        case pairing
        case paired
    }

    let speaker: String
    /// Where the speaker says its token is (pairing.md, pair-method descriptor `locations`).
    let locations: [PairMethods.Location]
    let phase: Phase
    /// Its QR code is being scanned in the scan window.
    let scanning: Bool
    /// Past the row's icon in the menu; Settings has none.
    var indent = destinationIndent
    /// Opens the scan window, or brings it forward.
    let onScan: () -> Void
    let onPair: (PairingToken.PairingPSK) -> Void
    @State private var text = ""
    @State private var unreadable = false
    /// Pasting chosen over scanning.
    @State private var pasting = false
    @FocusState private var focused: Bool

    /// Printed on it or its leaflet, and there's a camera to scan it with.
    private var scannable: Bool {
        (locations.contains(.device) || locations.contains(.leaflet)) && QRScanner.hasCamera
    }
    private var wrong: Bool { phase == .looking(again: true) || unreadable }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if scanning {
                Button("Scanning in a window…", action: onScan)
                    .buttonStyle(.link)
            } else if scannable && !pasting, case .looking = phase {
                Text((wrong ? "That token didn't match. " : "") + hint)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button(action: onScan) {
                        Label("Scan the QR Code", systemImage: "camera")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button("Or paste a token") {
                        pasting = true
                        focused = true
                    }
                    .buttonStyle(.link)
                }
            } else {
                switch phase {
                case .pairing:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Pairing with \(speaker)…")
                    }
                case .paired:
                    Label("Paired", systemImage: "checkmark")
                case .looking:
                    Text((wrong ? "That token didn't match. " : "") + prompt)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("Pairing token", text: $text, prompt: Text("SP:0…"))
                        .labelsHidden()
                        .font(.system(.caption, design: .monospaced))
                        .focused($focused)
                        .onSubmit(pair)
                        .onChange(of: text) { typed, now in
                            if let token = PairingToken.decodePairingPSK(now) {
                                submit(token)
                            } else if now.count - typed.count > 8 {
                                // Pasted, and not a token.
                                unreadable = true
                                text = ""
                            }
                        }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.caption)
        .padding(.leading, indent)
        .padding(.bottom, 6)
        .onAppear { if !scannable { focused = true } }
    }

    /// Where the QR code is, before scanning.
    private var hint: String {
        let onDevice = locations.contains(.device), onLeaflet = locations.contains(.leaflet)
        let place = onDevice && onLeaflet ? "on \(speaker) or its leaflet"
            : onDevice ? "on \(speaker)" : "on the leaflet that came with \(speaker)"
        return "The pairing token is the QR code \(place)."
    }

    /// Pasting: where the token is, if the speaker says.
    private var prompt: String {
        let onDevice = locations.contains(.device), onLeaflet = locations.contains(.leaflet)
        if onDevice && onLeaflet { return "Paste the token from the QR code on \(speaker) or its leaflet:" }
        if onDevice { return "Paste the token from the QR code on \(speaker):" }
        if onLeaflet { return "Paste the token from the QR code on the leaflet that came with \(speaker):" }
        if locations.contains(.operator) { return "Paste the pairing token you set up for \(speaker):" }
        return "Paste the pairing token of \(speaker):"
    }

    private func submit(_ token: PairingToken.PairingPSK) {
        unreadable = false
        onPair(token)
    }

    private func pair() {
        guard !text.isEmpty else { return }
        guard let token = PairingToken.decodePairingPSK(text) else {
            unreadable = true
            text = ""
            return
        }
        submit(token)
    }
}

/// Entering a pairing code: one slot per digit, grouped as the speaker groups them (`123-456`,
/// `1234-5678`). Typing and pasting go to a text field behind the slots; anything but digits
/// is left out.
private struct CodeEntry: View {
    let length: Int
    let onComplete: (String) -> Void
    @State private var digits = ""
    @FocusState private var focused: Bool

    var body: some View {
        let split = length / 2
        ZStack {
            TextField("Pairing code", text: $digits)
                .textFieldStyle(.plain)
                // In Settings' form its title would be a label beside it, widening the row.
                .labelsHidden()
                .focused($focused)
                .opacity(0.02)
                .onChange(of: digits) { _, typed in
                    let clean = String(typed.filter { $0.isASCII && $0.isNumber }.prefix(length))
                    if clean != typed { digits = clean }
                    if clean.count == length { onComplete(clean) }
                }
            HStack(spacing: 4) {
                ForEach(0..<length, id: \.self) { index in
                    if index == split {
                        Text("–").foregroundStyle(.secondary)
                    }
                    slot(index)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .fixedSize()
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .onAppear { focused = true }
    }

    private func slot(_ index: Int) -> some View {
        let characters = Array(digits)
        let current = index == characters.count && focused
        return Text(index < characters.count ? String(characters[index]) : " ")
            .font(.system(.body, design: .monospaced).weight(.medium))
            .frame(width: 20, height: 26)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(current ? Color.accentColor : .clear, lineWidth: 1.5))
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

/// The window the menu is shown in, to close it. SwiftUI has no way to dismiss a menu bar extra.
/// A plain reference: finding the window isn't something the view redraws for.
@MainActor
final class MenuWindow {
    weak var window: NSWindow?

    struct Reader: NSViewRepresentable {
        let found: MenuWindow

        func makeNSView(context: Context) -> NSView { View(found: found) }
        func updateNSView(_ nsView: NSView, context: Context) {}

        final class View: NSView {
            let found: MenuWindow

            init(found: MenuWindow) {
                self.found = found
                super.init(frame: .zero)
            }

            required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if let window { found.window = window }
            }
        }
    }
}
