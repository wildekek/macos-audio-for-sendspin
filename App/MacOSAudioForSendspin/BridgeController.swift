import AudioToolbox
import CoreAudio
import Foundation
import Observation
import SendspinAudio
import SendspinServerKit
import os

/// Owns the bridge: discovers players, keeps the selected ones in one group, captures
/// the Sendspin device and streams it, and links the device's volume/mute (volume keys,
/// Control Center) with the players. It also offers the Mac's audio to Music Assistant, as
/// a Sendspin source.
@MainActor
@Observable
final class BridgeController {
    struct Player: Identifiable {
        var id: String { instanceName }
        var instanceName: String
        var name: String
        var isSelected: Bool
        /// It plays the Mac's sound now: its icon is blue.
        var isActive: Bool
        var status: PlayerStatus?
        var isDiscovered: Bool
        /// It can be in a group with the others: every Sendspin speaker, and the Mac's own
        /// output unless it's AirPlay. Music Assistant isn't (see `playsGroupable`).
        var isGroupable = true
        /// The Mac's own speakers, not a Sendspin speaker.
        var isLocal: Bool { instanceName == BridgeController.localKey }
    }

    /// Where the Mac's audio goes: the speakers ticked here, in sync, or Music Assistant,
    /// which plays it on whatever it chooses. One at a time: the two aren't in sync.
    enum Destination: String {
        case speakers, musicAssistant
    }

    enum Lead: Int, CaseIterable, Identifiable {
        case low = 300, normal = 600, robust = 1000
        var id: Int { rawValue }
    }

    /// Sample rate of the Sendspin device (and the capture), and the bit depth streamed.
    struct StreamFormat: Hashable, Identifiable, Comparable {
        var sampleRate: Int
        var bitDepth: Int
        var id: String { "\(sampleRate)/\(bitDepth)" }

        var label: String {
            let khz = Double(sampleRate) / 1000
            let rate = khz.rounded() == khz ? String(Int(khz)) : String(format: "%.1f", khz)
            return "\(rate) kHz · \(bitDepth)-bit"
        }

        static func < (lhs: StreamFormat, rhs: StreamFormat) -> Bool {
            (lhs.sampleRate, lhs.bitDepth) < (rhs.sampleRate, rhs.bitDepth)
        }
    }

    static let streamBitDepths = [16, 24]

    // MARK: State shown in the menu

    private(set) var discovered: [DiscoveredPlayer] = []
    private(set) var statuses: [String: PlayerStatus] = [:]
    private(set) var selected: Set<String>
    /// Sound is played to the Sendspin device (in the last few seconds), wherever it goes.
    private(set) var hasSound = false
    /// The Sendspin device is there (the driver is loaded).
    private(set) var driverInstalled = false
    /// Whether the installed driver is the one this app carries.
    private(set) var driverState = DriverInstaller.state
    private(set) var isInstallingDriver = false
    /// Installed, but the device didn't appear: coreaudiod didn't load it, a restart will.
    private(set) var driverNeedsRestart = false
    /// macOS refuses Local Network access: no speaker can be found or reached.
    private(set) var localNetworkDenied = false
    /// Discovery found that macOS allows Local Network access (neither is known before then).
    private(set) var localNetworkAllowed = false
    private(set) var isMacOutput = false
    private var currentOutputUID: String?
    private(set) var isSwitchingOutput = false
    /// The Sendspin device's volume and mute, linked to the speakers (volume keys, Control Center).
    private var deviceVolume: Float = 1
    private var deviceMuted = false
    private(set) var lead: Lead
    /// The lead the group and the device latency currently use (see `effectiveLeadMs`).
    private var appliedLeadMs: Int
    /// The format chosen in the menu; `activeFormat` is what's applied.
    private(set) var selectedFormat: StreamFormat
    private(set) var deviceSampleRate = 48_000
    private var deviceSampleRates: Set<Int> = []
    /// This Mac as a source for Music Assistant (or another Sendspin server).
    private(set) var sourceStatus: SourceStatus
    /// The chosen destination; `destination` is the one in effect.
    private(set) var chosenDestination: Destination

    /// The Mac's own speakers first, as in AirPlay's list, then the Sendspin speakers.
    var players: [Player] {
        guard localDevice != nil || selected.contains(Self.localKey) else { return speakers }
        // Played directly they're ticked, whatever was ticked before.
        let local = Player(instanceName: Self.localKey, name: localDevice?.name ?? "This Mac",
                           isSelected: isDirect || (showsSpeakerTicks && selected.contains(Self.localKey)),
                           isActive: isDirect || (playsOnSpeakers && selected.contains(Self.localKey)),
                           status: statuses[Self.localKey] ?? (isDirect ? directStatus : nil),
                           isDiscovered: localDevice != nil, isGroupable: localCanPlayAlong)
        return [local] + speakers
    }

    /// The Sendspin speakers.
    var speakers: [Player] {
        var names = Set(discovered.map(\.instanceName)).union(selected)
        names.formUnion(statuses.keys)
        names.remove(Self.localKey)
        return names.sorted().map { name in
            let discovery = discovered.first { $0.instanceName == name }
            // A speaker that left shows unticked, as AirPlay does: ticking takes it back.
            let isSelected = showsSpeakerTicks && selected.contains(name) && statuses[name]?.connection != .left
            return Player(instanceName: name,
                          // The name it told us, also while it's away: mDNS often has only an ID.
                          name: statuses[name]?.name ?? playerNames[name] ?? discovery?.displayName ?? name,
                          isSelected: isSelected,
                          isActive: playsOnSpeakers && isSelected,
                          status: statuses[name],
                          // A player that connected to us is "discovered" while it's connected.
                          isDiscovered: discovery != nil || (Self.isIncoming(name) && sessions[name] != nil))
        }
    }

    var hasConnectedPlayers: Bool { statuses.values.contains { $0.connection == .connected } }

    /// A ticked Sendspin speaker is connected: the Mac's own speakers don't count, as there's
    /// nothing to play along with without one.
    private var hasConnectedSpeakers: Bool {
        statuses.contains { $0.key != Self.localKey && $0.value.connection == .connected }
    }

    /// Sendspin is the Mac's output, or becomes it once an added speaker connects.
    private var isOn: Bool { isMacOutput || waitsForSpeaker }

    /// The Mac plays on its own speakers directly, without Sendspin and its delay: chosen here
    /// (ticked alone) or anywhere else, such as Control Center.
    var isDirect: Bool {
        !isMacOutput && localDevice != nil && currentOutputUID == localDevice?.uid
    }

    /// The speakers get the Mac's sound.
    private var playsOnSpeakers: Bool { isMacOutput && destination == .speakers }

    /// What plays now is groupable. Not Music Assistant, which plays where it chooses, nor an
    /// AirPlay output played directly (macOS removes it once Sendspin is the output). While
    /// it isn't, nothing can join it: the checks go, and a name plays there instead.
    var playsGroupable: Bool {
        !(isMacOutput && destination == .musicAssistant) && !(isDirect && !localCanPlayAlong)
    }


    /// The group shows what plays, or will once an added speaker connects. While the Mac plays
    /// directly or Music Assistant plays, the Sendspin speakers show as not in it.
    private var showsSpeakerTicks: Bool { playsOnSpeakers || waitsForSpeaker }

    /// The Mac's sound is playing: on a connected speaker, or through Music Assistant's open
    /// stream. Without sound it's Idle; without either it's not set up yet.
    var isPlaying: Bool {
        hasSound && (destination == .speakers ? hasConnectedPlayers : sourceStatus.streaming)
    }

    /// Music Assistant found this Mac, or is paired with it: the menu offers the choice.
    var offersMusicAssistant: Bool { sourceStatus.connected || sourceStatus.hasPairing }

    /// Speakers, unless Music Assistant is chosen and offered.
    var destination: Destination { offersMusicAssistant ? chosenDestination : .speakers }

    /// Music Assistant can take the Mac's audio: chosen, paired and connected.
    var musicAssistantReady: Bool { destination == .musicAssistant && sourceStatus.paired }

    /// A Sendspin speaker is ticked.
    var hasSelectedSpeakers: Bool { speakers.contains(where: \.isSelected) }

    /// Sendspin speakers was chosen before any speaker could play: the Mac's output switches
    /// to Sendspin once one is connected, and until then the menu asks to tick one.
    private var pendingSendspinOutput = false
    var waitsForSpeaker: Bool { pendingSendspinOutput && !isMacOutput }

    /// The name this Mac goes by in Music Assistant.
    var macName: String { identity.name }

    /// A page of Music Assistant's web interface, as it advertises it over mDNS; `route` is
    /// the part after the #, e.g. "/browse".
    func musicAssistantPage(_ route: String) -> URL? {
        guard let url = musicAssistantURL, var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        if components.path.isEmpty { components.path = "/" }
        components.fragment = route
        return components.url
    }

    /// Music Assistant's web interface: the `_mass._tcp` record with the source server's name.
    private var musicAssistantURL: URL? {
        guard let name = sourceServerFullName else { return nil }
        return musicAssistantServers.first { $0.name == name }?.url
    }

    /// The server this Mac is a source for: the one connected, or else the one paired.
    private var sourceServerFullName: String? {
        sourceStatus.serverName ?? sourceStatus.pairedServerNames.first
    }

    /// That server is Music Assistant: a `_mass._tcp` record has its name, now or before. It
    /// decides the logo and the links only; the instructions are the same for any server.
    var sourceServerIsMusicAssistant: Bool {
        guard let name = sourceServerFullName else { return true }
        return musicAssistantNames.contains(name) || musicAssistantServers.contains { $0.name == name }
    }

    /// The server's name; Music Assistant's without the id it adds, e.g. "Music Assistant (d536…)".
    var sourceServerName: String {
        guard let name = sourceServerFullName else { return "Music Assistant" }
        guard sourceServerIsMusicAssistant else { return name }
        return name.replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression)
    }

    /// Names of the Music Assistant servers seen, so one keeps its logo while it's away.
    private var musicAssistantNames: Set<String> {
        get { Set(defaults.stringArray(forKey: "musicAssistantNames") ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: "musicAssistantNames") }
    }

    /// Formats at least one connected speaker supports, at rates the device offers.
    /// Speakers that don't support the active format get it converted.
    var availableFormats: [StreamFormat] {
        let formats = statuses.values.filter { $0.connection == .connected }.flatMap(\.supportedFormats)
            .filter { Self.streamBitDepths.contains($0.bitDepth) && deviceSampleRates.contains($0.sampleRate) }
            .map { StreamFormat(sampleRate: $0.sampleRate, bitDepth: $0.bitDepth) }
        return Set(formats).sorted()
    }

    /// The selected format, or the closest available one while it's unavailable.
    var activeFormat: StreamFormat? {
        let available = availableFormats
        if available.contains(selectedFormat) { return selectedFormat }
        let sameRate = available.filter { $0.sampleRate == selectedFormat.sampleRate }
        return sameRate.last { $0.bitDepth <= selectedFormat.bitDepth } ?? sameRate.first
            ?? available.min { abs($0.sampleRate - selectedFormat.sampleRate) < abs($1.sampleRate - selectedFormat.sampleRate) }
    }

    // MARK: Internals

    private let defaults = UserDefaults.standard
    private let group: PlaybackGroup
    private let identity: ServerIdentity
    private let source: SourceClient
    /// Whether captured audio goes to the speakers; the capture pump reads it per block.
    private let speakerRoute = SpeakerRoute()
    /// Speakers found over mDNS, before leaving out this Mac's own source advertisement.
    private var browsed: [DiscoveredPlayer] = []
    private var sessions: [String: PlayerSession] = [:]
    /// The Mac's own output, while there is one: in the speaker list as `localKey`.
    private var localDevice: AudioDevice?
    /// Plays on it while it's ticked, in sync with the Sendspin speakers.
    private var localPlayer: LocalPlayer?
    private var localObservations: [PropertyObservation] = []
    private var capture: DriverCapture?
    private var isStartingCapture = false
    private var formatSwitch = FormatSwitch()
    private var pumpTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var musicAssistantTask: Task<Void, Never>?
    private var musicAssistantServers: [MusicAssistantServer] = []
    private var listener: ServiceListener?
    private var systemObservations: [PropertyObservation] = []
    private var deviceObservations: [PropertyObservation] = []
    /// Volume we just wrote to the device ourselves; its change notification is not a user action.
    private var expectedDeviceVolume: Float?

    init() {
        let defaults = UserDefaults.standard
        let lead = Lead(rawValue: defaults.integer(forKey: "leadMs")) ?? .low
        // The pre-1.0 server ID; Sendspin 1 identifies the server by its Noise key.
        defaults.removeObject(forKey: "serverID")
        // Earlier versions remembered only the names of players that connected to us.
        if let names = defaults.dictionary(forKey: "incomingNames") {
            defaults.set(names, forKey: "playerNames")
            defaults.removeObject(forKey: "incomingNames")
        }
        let identity = IdentityStore.load(name: Host.current().localizedName ?? "Mac")
        selected = Set(defaults.stringArray(forKey: "selectedPlayers") ?? [])
        selectedFormat = StreamFormat(sampleRate: defaults.object(forKey: "sampleRate") as? Int ?? 48_000,
                                      bitDepth: defaults.object(forKey: "bitDepth") as? Int ?? 16)
        self.lead = lead
        appliedLeadMs = lead.rawValue
        self.identity = identity
        group = PlaybackGroup(name: identity.name, leadMs: lead.rawValue)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        source = SourceClient(name: identity.name, softwareVersion: version,
                              credentials: SourceCredentialsStore.load(), save: SourceCredentialsStore.save)
        sourceStatus = SourceStatus()
        chosenDestination = Destination(rawValue: defaults.string(forKey: "destination") ?? "") ?? .speakers

        Log.minimumLevel = defaults.bool(forKey: "verboseLogging") ? .debug : .info
        let logger = Logger(subsystem: "eu.vooijs.MacOSAudioForSendspin", category: "bridge")
        Log.handler = { level, message in
            switch level {
            case .debug: logger.debug("\(message, privacy: .public)")
            case .info: logger.info("\(message, privacy: .public)")
            case .warning: logger.warning("\(message, privacy: .public)")
            case .error: logger.error("\(message, privacy: .public)")
            }
            // Info and debug messages aren't persisted by unified logging; mirror them to
            // stderr so a terminal launch (or a redirected log file) shows everything.
            FileHandle.standardError.write(Data("\(level) \(message)\n".utf8))
        }

        Task { await start() }
    }

    private func start() async {
        Log.info("Starting (\(identity.name), lead \(lead.rawValue) ms)")
        observeSystem()
        refreshDevice()
        // On the first launch the welcome window asks for each permission at its step.
        if isWelcomeDone {
            startDiscovery()
        }
        Self.forgetMicrophonePermission()
    }

    /// Versions up to 0.6.1 recorded the Sendspin device's input, so they asked for the
    /// microphone; this one reads its audio from the driver and can't use the microphone at
    /// all. A drag-and-drop update keeps that permission, and the app would stay listed under
    /// Microphone in Privacy & Security: forget it, once. It's the user's own privacy setting,
    /// so no administrator rights are needed; until it works, it's tried at each launch.
    private nonisolated static func forgetMicrophonePermission() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "microphonePermissionForgotten"),
              let bundleID = Bundle.main.bundleIdentifier else { return }
        Task.detached {
            let tccutil = Process()
            tccutil.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            tccutil.arguments = ["reset", "Microphone", bundleID]
            tccutil.standardOutput = FileHandle.nullDevice
            tccutil.standardError = FileHandle.nullDevice
            do {
                try tccutil.run()
                tccutil.waitUntilExit()
            } catch {
                Log.warning("Couldn't forget the microphone permission: \(error)")
                return
            }
            guard tccutil.terminationStatus == 0 else {
                Log.warning("Couldn't forget the microphone permission (tccutil \(tccutil.terminationStatus))")
                return
            }
            defaults.set(true, forKey: "microphonePermissionForgotten")
            Log.info("Forgot the microphone permission earlier versions asked for")
        }
    }

    // MARK: First launch

    /// The welcome window was finished or closed; until then, nothing asks for permissions.
    private(set) var isWelcomeDone = UserDefaults.standard.bool(forKey: "welcomeDone")

    /// Close the welcome flow, and start whatever it didn't get to.
    func finishWelcome() async {
        guard !isWelcomeDone else { return }
        isWelcomeDone = true
        defaults.set(true, forKey: "welcomeDone")
        startDiscovery()
    }

    var isDiscovering: Bool { discoveryTask != nil }

    /// Browsing for speakers is what triggers the Local Network prompt.
    func startDiscovery() {
        guard discoveryTask == nil else { return }
        startListening()
        let denied: @Sendable (Bool) -> Void = { [weak self] denied in
            Task { @MainActor in
                guard let self else { return }
                self.localNetworkAllowed = !denied
                guard self.localNetworkDenied != denied else { return }
                Log.info("Local Network access \(denied ? "denied" : "allowed")")
                self.localNetworkDenied = denied
            }
        }
        discoveryTask = Task { [weak self] in
            for await players in PlayerBrowser.browse(localNetworkDenied: denied) {
                guard let self else { return }
                Log.debug("Discovered: \(players.map { "\($0.instanceName) \($0.url.absoluteString)" })")
                browsed = players
                updateDiscovered()
            }
        }
        musicAssistantTask = Task { [weak self] in
            for await servers in MusicAssistantBrowser.browse() {
                Log.debug("Music Assistant found: \(servers.map { "\($0.name ?? "?") \($0.url.absoluteString)" })")
                guard let self else { return }
                musicAssistantServers = servers
                let names = Set(servers.compactMap(\.name))
                if !names.isSubset(of: musicAssistantNames) { musicAssistantNames.formUnion(names) }
            }
        }
        startSource()
    }

    /// The browsed speakers and the manual ones, without this Mac: it advertises itself as
    /// a Sendspin client too, for Music Assistant.
    private func updateDiscovered() {
        let previous = Set(discovered.map(\.instanceName))
        discovered = browsed.filter { $0.instanceName != sourceStatus.advertisedName } + manualPlayers()
        // A ticked speaker that said goodbye and announces itself again is back: connect to it
        // anew, as after a lost power cable. Not one whose own user disconnected this Mac.
        for player in discovered where !previous.contains(player.instanceName) {
            if case .disconnected(let reason) = statuses[player.instanceName]?.connection, reason != "user_request" {
                Log.info("\(player.instanceName) is back; connecting again")
                dropSession(player.instanceName)
            }
        }
        reconcile()
    }

    /// Players configured by address (`manualPlayers`: ws:// URLs), for networks
    /// where mDNS doesn't reach them. Named by host:port.
    private func manualPlayers() -> [DiscoveredPlayer] {
        (defaults.stringArray(forKey: "manualPlayers") ?? []).compactMap { string in
            guard let url = URL(string: string), url.scheme == "ws", let host = url.host() else { return nil }
            let name = url.port.map { "\(host):\($0)" } ?? host
            return DiscoveredPlayer(instanceName: name, displayName: nil, url: url)
        }
    }

    // MARK: Player selection

    func setSelected(_ instanceName: String, _ isSelected: Bool) {
        if isSelected {
            selected.insert(instanceName)
            // Choosing a player that shows "Identity changed" accepts its new identity: the
            // user picks it knowingly. It reconnects below, and the new identity is approved.
            if statuses[instanceName]?.connection == .notApproved {
                var approved = approvedPlayers
                approved[instanceName] = nil
                defaults.set(approved, forKey: "approvedPlayers")
                Log.info("\(instanceName): accepting its new identity")
            }
            // Re-selecting a player that left or was taken over reconnects it.
            if let status = statuses[instanceName], status.connection.isFinal { dropSession(instanceName) }
            // A player that left the group for something else comes back on the same connection.
            if statuses[instanceName]?.connection == .left, let session = sessions[instanceName] {
                Task { await session.rejoin() }
            }
            // A player that connected to us and waits: allow it on the same connection.
            if Self.isIncoming(instanceName), let session = sessions[instanceName] {
                Task { await session.reevaluateApproval() }
            }
        } else {
            selected.remove(instanceName)
            // Unticking withdraws the approval; ticking again approves whatever identity shows up.
            var approved = approvedPlayers
            approved[instanceName] = nil
            defaults.set(approved, forKey: "approvedPlayers")
            // A player that connected to us: close it; it reconnects and waits, unticked.
            if Self.isIncoming(instanceName) { dropSession(instanceName) }
        }
        defaults.set(Array(selected), forKey: "selectedPlayers")
        reconcile()
    }

    /// Clicking a name, as in AirPlay: play on this speaker only. The checkboxes add and remove.
    func selectOnly(_ instanceName: String) {
        for other in selected where other != instanceName { setSelected(other, false) }
        setSelected(instanceName, true)
    }

    /// Approved players: instance name → the `client_id` approved for it.
    private var approvedPlayers: [String: String] {
        defaults.dictionary(forKey: "approvedPlayers") as? [String: String] ?? [:]
    }

    /// Ticking a player is the user's approval for unpaired playback (pairing.md, Unpaired
    /// Access), bound to the identity the player first presents. A different identity under
    /// the same name isn't approved: a new device can't pass for a known one by its name.
    private func approve(_ instanceName: String, clientID: String) -> Bool {
        guard selected.contains(instanceName) else { return false }
        var approved = approvedPlayers
        if let known = approved[instanceName] { return known == clientID }
        approved[instanceName] = clientID
        defaults.set(approved, forKey: "approvedPlayers")
        Log.info("\(instanceName): approved (\(clientID))")
        return true
    }

    /// Bring sessions in line with the selection and what's discoverable.
    private func reconcile() {
        for (name, session) in sessions where !Self.isIncoming(name) {
            // Drop deselected players, and players that moved to another address.
            let currentURL = discovered.first { $0.instanceName == name }?.url
            if !selected.contains(name) || (currentURL != nil && currentURL != session.url) {
                dropSession(name)
            }
        }
        for player in discovered where selected.contains(player.instanceName) && sessions[player.instanceName] == nil {
            addSession(for: player)
        }
        reconcileLocal()
        updateCapture()
    }

    private func addSession(for player: DiscoveredPlayer) {
        let name = player.instanceName
        let session = PlayerSession(url: player.url, identity: identity) { [weak self] clientID in
            await self?.approve(name, clientID: clientID) ?? false
        }
        sessions[name] = session
        statuses[name] = PlayerStatus()
        Task { [weak self] in
            for await status in session.updates {
                self?.playerStatusChanged(name, status)
            }
        }
        Task { await group.add(session) }
    }

    private func dropSession(_ name: String) {
        guard let session = sessions.removeValue(forKey: name) else { return }
        statuses[name] = nil
        Task { await group.remove(url: session.url) }
    }

    // MARK: The Mac's own speakers

    /// The Mac's own output in the speaker list: its speakers, AirPods, a USB DAC. It's no
    /// Sendspin player: `LocalPlayer` plays the group's audio on it directly, on the same clock.
    nonisolated static let localKey = "local:built-in"

    /// The Mac's own output: the one it uses or used last besides Sendspin, while it's there,
    /// or else its built-in headphones when plugged in, or its speakers.
    nonisolated private static func localOutput(previousUID: String?) -> AudioDevice? {
        if let previous = previousUID.flatMap(AudioDevice.find(uid:)) { return previous }
        let builtIn = AudioDevice.builtInOutputs()
        return builtIn.first(where: \.isHeadphones) ?? builtIn.first
    }

    /// Whether the built-in headphones were there at the last look; nil before the first.
    private var headphonesPluggedIn: Bool?

    /// Plugging in headphones makes them the Mac's own output in place of its built-in
    /// speakers, as macOS does when it plays on those: also while it plays through Sendspin.
    private func followPluggedInHeadphones() {
        let headphones = AudioDevice.builtInOutputs().first(where: \.isHeadphones)
        defer { headphonesPluggedIn = headphones != nil }
        guard headphonesPluggedIn == false, let headphones, let uid = headphones.uid,
              let previous = defaults.string(forKey: "previousOutputUID").flatMap(AudioDevice.find(uid:)),
              previous.transportType == kAudioDeviceTransportTypeBuiltIn, !previous.isHeadphones
        else { return }
        Log.info("Headphones plugged in: the Mac's own output is \(headphones.name ?? uid)")
        defaults.set(uid, forKey: "previousOutputUID")
    }

    /// It can play along with the Sendspin speakers. An AirPlay output can't: macOS only has
    /// the device while it's the Mac's output, and removes it once Sendspin is.
    var localCanPlayAlong: Bool {
        localDevice?.transportType != kAudioDeviceTransportTypeAirPlay
    }

    /// Its icon, as the macOS Sound menu has it.
    var localIcon: String {
        guard let localDevice else { return "laptopcomputer" }
        let name = localDevice.name ?? ""
        switch localDevice.transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            if localDevice.isHeadphones { return "headphones" }
            return name.localizedCaseInsensitiveContains("MacBook") ? "laptopcomputer" : "desktopcomputer"
        case kAudioDeviceTransportTypeAirPlay:
            if name.localizedCaseInsensitiveContains("HomePod mini") { return "homepodmini.fill" }
            if name.localizedCaseInsensitiveContains("HomePod") { return "homepod.fill" }
            if name.localizedCaseInsensitiveContains("Apple TV") { return "appletv.fill" }
            return "airplayaudio"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            if name.localizedCaseInsensitiveContains("AirPods Max") { return "airpodsmax" }
            if name.localizedCaseInsensitiveContains("AirPods Pro") { return "airpodspro" }
            if name.localizedCaseInsensitiveContains("AirPods") { return "airpods" }
            return "headphones"
        default:
            return "speaker.wave.2.fill"
        }
    }

    private func refreshLocalDevice() {
        followPluggedInHeadphones()
        let device = Self.localOutput(previousUID: defaults.string(forKey: "previousOutputUID"))
        guard device != localDevice else { return }
        localDevice = device
        // Its volume can change elsewhere too, e.g. in Audio MIDI Setup.
        localObservations = device.map { device in
            [device.observe(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                            scope: kAudioObjectPropertyScopeOutput) { [weak self] in
                Task { @MainActor in self?.updateLocalStatus() }
            }]
        } ?? []
        reconcileLocal()
        updateCapture()
    }

    /// A player on the Mac's output while it's ticked; a new one when the output changed.
    private func reconcileLocal() {
        let wanted = selected.contains(Self.localKey) && localCanPlayAlong ? localDevice : nil
        guard localPlayer?.device != wanted else { return }
        if let old = localPlayer {
            localPlayer = nil
            Task.detached { [group] in
                await group.remove(output: old)
                old.shutdown()
            }
        }
        if let wanted {
            let player = LocalPlayer(device: wanted)
            player.isMuted = deviceMuted
            localPlayer = player
            Task { await group.add(output: player) }
        }
        updateLocalStatus()
    }

    /// The device's own volume, 0…100: the slider in its row.
    private var localVolume: Int?

    /// Its status in the list: always connected, with the device's own volume. Only while
    /// it's ticked does it count in the group (its volume, whether a speaker is connected).
    private func updateLocalStatus() {
        localVolume = localDevice?.mainVolume.map { Int(($0 * 100).rounded()) }
        guard let localPlayer else {
            statuses[Self.localKey] = nil
            return
        }
        var status = directStatus
        status.canMute = true
        status.muted = localPlayer.isMuted
        // The Mac's own output can need more than the speaker buffer gives: the group waits for it.
        status.requiredBufferMs = localPlayer.requiredLeadMs
        guard status != statuses[Self.localKey] else { return }
        statuses[Self.localKey] = status
        syncDeviceToPlayers()
        applyLead()
    }

    /// Its row while the Mac plays on it directly: its volume is the Mac's volume then.
    private var directStatus: PlayerStatus {
        var status = PlayerStatus()
        status.connection = .connected
        status.name = localDevice?.name
        status.volume = localVolume
        status.canSetVolume = localVolume != nil
        return status
    }

    // MARK: Ticking in the menu

    /// The icon in a row: adding to or removing from the group. A Sendspin speaker needs
    /// Sendspin as the Mac's output; the Mac's own output alone plays directly, as there's
    /// nothing to keep in sync with.
    func setTicked(_ instanceName: String, _ ticked: Bool) {
        if instanceName == Self.localKey {
            if ticked, !localCanPlayAlong {
                playOnly(Self.localKey)
            } else if ticked {
                setSelected(Self.localKey, true)
                if hasSelectedSpeakers { chooseSpeakers() } else { playDirect() }
            } else if !isDirect {
                // Played directly they're the Mac's only output: they stay ticked.
                setSelected(Self.localKey, false)
            }
        } else if ticked {
            if !showsSpeakerTicks {
                // Ticking starts from what plays now, not from the speakers ticked before. The
                // Mac's own output keeps playing, now in sync, unless it's AirPlay.
                for name in selected where name != Self.localKey && name != instanceName { setSelected(name, false) }
                setSelected(Self.localKey, isDirect && localCanPlayAlong)
            }
            setSelected(instanceName, true)
            chooseSpeakers()
        } else {
            setSelected(instanceName, false)
            leaveSendspinIfIdle()
        }
    }

    /// What's in the group: what plays, and what's added and not playing yet.
    var groupCount: Int { players.filter(\.isSelected).count }

    /// Clicking a name, as in the Sound menu: play there only.
    func playOnly(_ instanceName: String) {
        if instanceName == Self.localKey {
            for name in selected where name != Self.localKey { setSelected(name, false) }
            setSelected(Self.localKey, true)
            playDirect()
        } else {
            selectOnly(instanceName)
            chooseSpeakers()
        }
    }

    /// Without a Sendspin speaker ticked there's nothing to play along with: the Mac's own
    /// speakers, when ticked, play directly, and otherwise the Mac goes back to its own output.
    private func leaveSendspinIfIdle() {
        guard isOn, destination == .speakers, !hasSelectedSpeakers else { return }
        if selected.contains(Self.localKey) { playDirect() } else { chooseMac() }
    }

    /// The Mac's output becomes its own speakers.
    private func playDirect() {
        pendingSendspinOutput = false
        guard let localDevice, !isDirect, !isSwitchingOutput else { return }
        isSwitchingOutput = true
        Task {
            defer { isSwitchingOutput = false }
            apply(await Task.detached {
                do {
                    try AudioDevice.setDefaultOutput(localDevice)
                } catch {
                    Log.error("Couldn't change the Mac's output: \(error)")
                }
                return Self.readOutput()
            }.value)
        }
    }

    // MARK: Music Assistant

    /// Advertise this Mac as a Sendspin source: Music Assistant finds it, and once paired
    /// (with the token from Settings) can play its audio anywhere.
    private func startSource() {
        let source = source
        let sending = chosenDestination == .musicAssistant
        Task { [weak self] in
            await source.start()
            // Always available: the Speakers tab sends silence instead (see applyDestination).
            await source.setAvailable(true)
            await source.setSending(sending)
            for await status in source.statusUpdates {
                self?.sourceStatusChanged(status)
            }
        }
    }

    /// Called when a server starts pairing by a code shown on this Mac (the code), and when
    /// that ends (nil). The app shows it in a window of its own.
    var onPairingCode: ((String?) -> Void)?

    private func sourceStatusChanged(_ status: SourceStatus) {
        let advertisedChanged = status.advertisedName != sourceStatus.advertisedName
        if status.pairingCode != sourceStatus.pairingCode { onPairingCode?(status.pairingCode) }
        sourceStatus = status
        applyDestination()
        if advertisedChanged { updateDiscovered() } else { updateCapture() }
    }

    // MARK: Choosing where the sound goes

    /// Sendspin speakers: the Mac's output becomes Sendspin, now or once a speaker connects.
    /// With one speaker and nothing ticked, choosing Sendspin speakers means that one: it's ticked.
    func chooseSpeakers() {
        let speakers = speakers
        if !hasSelectedSpeakers, speakers.count == 1, let only = speakers.first {
            setSelected(only.instanceName, true)
        }
        setDestination(.speakers)
        guard !isMacOutput else { return }
        if hasConnectedSpeakers {
            pendingSendspinOutput = false
            Task { await setMacOutput(true) }
        } else {
            pendingSendspinOutput = true
        }
    }

    /// Music Assistant, once paired: the Mac's output becomes Sendspin, and Music Assistant
    /// gets the audio.
    func chooseMusicAssistant() {
        guard sourceStatus.paired else { return }
        pendingSendspinOutput = false
        setDestination(.musicAssistant)
        if !isMacOutput { Task { await setMacOutput(true) } }
    }

    /// The Mac's own output again.
    func chooseMac() {
        pendingSendspinOutput = false
        if isMacOutput { Task { await setMacOutput(false) } }
    }

    func setDestination(_ destination: Destination) {
        chosenDestination = destination
        defaults.set(destination.rawValue, forKey: "destination")
        applyDestination()
        updateCapture()
    }

    /// Route the audio: to the speakers, or to Music Assistant. Either side stays connected,
    /// so switching back is immediate. Music Assistant gets silence meanwhile, like a line-in
    /// whose source went quiet: reporting the Mac unavailable would end its stream, and it
    /// would only play again once someone starts the input anew.
    private func applyDestination() {
        let toSpeakers = destination == .speakers
        guard toSpeakers != speakerRoute.isOn else { return }
        speakerRoute.set(toSpeakers)
        let source = source
        Task { await source.setSending(!toSpeakers) }
        if !toSpeakers {
            Task { await group.setPlaying(false) }
        }
    }

    /// Forget every pairing: Music Assistant needs the token again.
    func forgetMusicAssistant() {
        let source = source
        Task { await source.forgetPairings() }
    }

    // MARK: Players that connect to us

    /// Players that look for a server themselves (client-initiated connections) find this
    /// Mac over mDNS and connect. They wait, unticked, until the user allows them.
    private func startListening() {
        guard listener == nil else { return }
        let listener = ServiceListener(name: identity.name, kind: .server)
        self.listener = listener
        listener.start()
        Task { [weak self] in
            for await connection in listener.connections {
                self?.accept(connection)
            }
        }
    }

    /// Such a player has no mDNS name; its identity is its key.
    static func incomingKey(_ clientID: String) -> String { "client:" + clientID }
    static func isIncoming(_ name: String) -> Bool { name.hasPrefix("client:") }

    private func accept(_ connection: IncomingConnection) {
        let session = PlayerSession(incoming: connection, identity: identity) { [weak self] clientID in
            await self?.approveIncoming(clientID) ?? false
        }
        Task { await group.add(session) }
        Task { [weak self] in
            var key: String?
            for await status in session.updates {
                guard let self else { return }
                // Known once the handshake told its identity and the hello its name.
                if key == nil, let clientID = status.clientID, let name = status.name {
                    key = adoptIncoming(session, clientID: clientID, name: name)
                }
                if let key { playerStatusChanged(key, status) }
            }
            // It left: forget the connection (a ticked one shows as unavailable).
            guard let self else { return }
            if let key, sessions[key] === session { dropSession(key) } else { Task { await group.remove(url: session.url) } }
        }
    }

    private func adoptIncoming(_ session: PlayerSession, clientID: String, name: String) -> String {
        let key = Self.incomingKey(clientID)
        // A reconnect replaces its earlier connection.
        if let old = sessions[key], old !== session { dropSession(key) }
        sessions[key] = session
        statuses[key] = PlayerStatus()
        Log.info("\(name) connected to us (\(clientID))")
        return key
    }

    /// Ticking a player that connected to us allows it; its key is its identity, so the
    /// approval is bound to it by construction.
    private func approveIncoming(_ clientID: String) -> Bool {
        let key = Self.incomingKey(clientID)
        guard selected.contains(key) else { return false }
        var approved = approvedPlayers
        approved[key] = clientID
        defaults.set(approved, forKey: "approvedPlayers")
        return true
    }

    /// The names players told us in their hello, so the list shows the same name while one is
    /// unticked or away. A player that connected to us has no other name at all.
    private var playerNames: [String: String] {
        get { defaults.dictionary(forKey: "playerNames") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "playerNames") }
    }

    private func playerStatusChanged(_ name: String, _ status: PlayerStatus) {
        guard sessions[name] != nil else { return }
        if let playerName = status.name, playerNames[name] != playerName { playerNames[name] = playerName }
        let formatsChanged = statuses[name]?.supportedFormats != status.supportedFormats
            || statuses[name]?.connection != status.connection
        statuses[name] = status
        if pendingSendspinOutput, destination == .speakers, hasConnectedSpeakers {
            pendingSendspinOutput = false
            if !isMacOutput { Task { await setMacOutput(true) } }
        }
        syncDeviceToPlayers()
        applyLead()
        if formatsChanged { applyFormat() }
    }

    // MARK: Capture

    /// Speakers to play to, or Music Assistant: as the destination, or with its stream open
    /// (it keeps getting silence, so the stream lives on for when it's chosen again). The Mac's
    /// own output only while Sendspin is the Mac's output: played directly, it needs nothing.
    private var isCaptureWanted: Bool {
        return destination == .speakers
            ? !sessions.isEmpty || (localPlayer != nil && isMacOutput) || sourceStatus.streaming
            : musicAssistantReady
    }

    private func updateCapture() {
        if isCaptureWanted, capture == nil, !isStartingCapture, let device = AudioDevice.sendspin {
            isStartingCapture = true
            let soundChanged: @Sendable (Bool) async -> Void = { [weak self] sound in
                await self?.setHasSound(sound)
            }
            Task {
                // Creating and starting the queue waits on coreaudiod, for a freshly loaded
                // device noticeably: keep it off the main thread. Capture at the device's own
                // rate: no conversion before the speakers.
                let started = await Task.detached {
                    Result { () throws -> DriverCapture in
                        let capture = try DriverCapture(device: device)
                        try capture.start()
                        return capture
                    }
                }.value
                isStartingCapture = false
                switch started {
                case .success(let capture):
                    // The selection may have changed while it started.
                    guard isCaptureWanted, self.capture == nil else {
                        Task.detached { capture.stop() }
                        updateCapture()
                        return
                    }
                    self.capture = capture
                    pumpTask = Task.detached { [self, group, source, speakerRoute] in
                        await Self.pump(capture.blocks, into: group, source: source, route: speakerRoute,
                                        soundChanged: soundChanged)
                        await captureEnded(capture)
                    }
                    Log.info("Capturing from \(capture.deviceName) at \(capture.sampleRate) Hz")
                case .failure(let error):
                    Log.error("Capture failed: \(error)")
                }
            }
        } else if !isCaptureWanted, capture != nil {
            stopCapture()
            hasSound = false
            Task { await group.setPlaying(false) }
            Log.info("Capture stopped")
        }
    }

    private func stopCapture() {
        pumpTask?.cancel()
        if let capture { Task.detached { capture.stop() } }  // stopping waits on coreaudiod too
        capture = nil
    }

    /// The capture's blocks ended. Unless it was stopped here, it ended by itself: its reads
    /// kept failing, as when coreaudiod restarts and the device comes back under another
    /// object ID. Start again on the device as it is now, after a moment, so a device that
    /// keeps failing doesn't spin.
    private func captureEnded(_ ended: DriverCapture) async {
        guard capture === ended else { return }
        Log.info("Capture ended; starting again")
        capture = nil
        hasSound = false
        try? await Task.sleep(for: .seconds(1))
        updateCapture()
    }

    /// The device switched sample rate (from us, or e.g. Audio MIDI Setup). Capture follows
    /// by itself (each block carries its rate), and the bit depth that waited for the rate
    /// goes with it: players get one new stream/start in their (possibly new) format.
    private func deviceSampleRateChanged() {
        guard let rate = AudioDevice.sendspin.map({ Int($0.nominalSampleRate) }), rate != deviceSampleRate else { return }
        Log.info("Sendspin device now runs at \(rate) Hz")
        deviceSampleRate = rate
        formatSwitch.deviceRateChanged()
    }

    private func setHasSound(_ sound: Bool) {
        hasSound = sound
    }

    /// Forward captured audio; after a few seconds of digital silence the players get
    /// `stream/end`, and the stream restarts with the next sound. Music Assistant gets every
    /// block, silence too: it decides when to play, from the signal we report (and only
    /// streams while it's the destination). `soundChanged` reports whether there's sound,
    /// wherever it goes.
    nonisolated private static func pump(_ blocks: AsyncStream<CapturedBlock>, into group: PlaybackGroup,
                                         source: SourceClient, route: SpeakerRoute,
                                         soundChanged: @Sendable (Bool) async -> Void) async {
        let idleAfterUs: Int64 = 3_000_000
        var lastSoundUs: Int64?
        var streaming = false
        var sound = false
        for await block in blocks {
            // 16-bit: Music Assistant plays live inputs at 48 kHz/16-bit anyway.
            await source.deliver(block.pcm, captureTimeUs: block.captureTimeUs, bitDepth: 16)
            if !block.pcm.isSilent { lastSoundUs = block.captureTimeUs }
            let hasSound = lastSoundUs.map { block.captureTimeUs - $0 < idleAfterUs } ?? false
            let active = route.isOn && hasSound
            if active {
                await group.push(block.pcm, captureTimeUs: block.captureTimeUs)
            } else if streaming {
                await group.setPlaying(false)
            }
            streaming = active
            if hasSound != sound {
                sound = hasSound
                await soundChanged(hasSound)
            }
        }
    }

    // MARK: Device: volume, mute, default output, latency

    private func observeSystem() {
        systemObservations = [
            AudioDevice.observeSystem(kAudioHardwarePropertyDevices) { [weak self] in
                Task { @MainActor in self?.refreshDevice() }
            },
            AudioDevice.observeSystem(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
                Task { @MainActor in self?.refreshDefaultOutput() }
            },
        ]
    }

    /// (Re)attach to the Sendspin device, e.g. at launch or after the driver was installed.
    private func refreshDevice() {
        let started = ContinuousClock.now
        defer {
            // Still on the main thread (TODO): say when it's slow enough to be felt.
            let elapsed = ContinuousClock.now - started
            if elapsed > .milliseconds(100) { Log.warning("Reading the Sendspin device took \(elapsed)") }
        }
        let device = AudioDevice.sendspin
        driverInstalled = device != nil
        driverState = DriverInstaller.state
        if device != nil { driverNeedsRestart = false }
        deviceObservations = []
        refreshDefaultOutput()
        guard let device else {
            updateCapture()
            return
        }
        deviceVolume = device.volume ?? 1
        deviceMuted = device.isMuted ?? false
        deviceSampleRate = Int(device.nominalSampleRate)
        deviceSampleRates = Set(device.availableSampleRates.map { Int($0) })
        deviceObservations = [
            device.observe(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput) { [weak self] in
                Task { @MainActor in self?.deviceVolumeChanged() }
            },
            device.observe(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput) { [weak self] in
                Task { @MainActor in self?.deviceMuteChanged() }
            },
            device.observe(kAudioDevicePropertyNominalSampleRate) { [weak self] in
                Task { @MainActor in self?.deviceSampleRateChanged() }
            },
        ]
        applyPresentationLatency()
        applyFormat()
        updateCapture()
    }

    private func refreshDefaultOutput() {
        apply(Self.readOutput())
        refreshLocalDevice()
        updateCapture()
    }

    /// What the Mac's output is, and where leaving Sendspin would go.
    struct OutputState: Sendable {
        var isSendspin: Bool
        var currentUID: String?
    }

    nonisolated private static func readOutput() -> OutputState {
        let output = AudioDevice.defaultOutput
        return OutputState(isSendspin: output?.uid == AudioDevice.sendspinUID, currentUID: output?.uid)
    }

    private func apply(_ state: OutputState) {
        isMacOutput = state.isSendspin
        currentOutputUID = state.currentUID
        // Remember the last other output, also when it was chosen in Control Center.
        if let uid = state.currentUID, !state.isSendspin {
            defaults.set(uid, forKey: "previousOutputUID")
        }
    }

    /// Volume keys / Control Center / our group slider changed the device volume. With Music
    /// Assistant as the destination, its own volume applies and the idle speakers stay put.
    private func deviceVolumeChanged() {
        guard let volume = AudioDevice.sendspin?.volume else { return }
        deviceVolume = volume
        guard destination == .speakers else { return }
        if let expected = expectedDeviceVolume, abs(expected - volume) < 0.005 {
            expectedDeviceVolume = nil
            return
        }
        let current = connectedVolumes()
        let target = Int((volume * 100).rounded())
        guard GroupVolume.level(current) != target else { return }
        for (name, level) in GroupVolume.redistribute(current, to: target) where current[name] != level {
            setPlayerVolume(name, level)
        }
    }

    private func deviceMuteChanged() {
        guard let muted = AudioDevice.sendspin?.isMuted, muted != deviceMuted else { return }
        deviceMuted = muted
        guard destination == .speakers else { return }
        let targets = sessions.filter { statuses[$0.key]?.muted != muted }.map(\.value)
        for session in targets {
            Task { await session.setMuted(muted) }
        }
        localPlayer?.isMuted = muted
        updateLocalStatus()
    }

    /// A player's own volume changed (its knob, Music Assistant, or our command):
    /// show the new group level on the device, so the system volume HUD stays truthful.
    private func syncDeviceToPlayers() {
        guard let device = AudioDevice.sendspin else { return }
        if let level = GroupVolume.level(connectedVolumes()) {
            let scalar = Float(level) / 100
            if abs((device.volume ?? -1) - scalar) >= 0.005 {
                expectedDeviceVolume = scalar
                device.volume = scalar
            }
        }
        let mutes = statuses.values.filter { $0.connection == .connected }.compactMap(\.muted)
        if !mutes.isEmpty {
            let allMuted = mutes.allSatisfy { $0 }
            if allMuted != deviceMuted {
                deviceMuted = allMuted
                device.isMuted = allMuted
            }
        }
    }

    private func connectedVolumes() -> [String: Int] {
        statuses.compactMapValues { $0.connection == .connected ? $0.volume : nil }
    }

    // MARK: Menu actions

    func setPlayerVolume(_ instanceName: String, _ volume: Int) {
        if instanceName == Self.localKey {
            localDevice?.mainVolume = Float32(volume) / 100
            updateLocalStatus()
        } else {
            Task { await sessions[instanceName]?.setVolume(volume) }
        }
    }

    func selectFormat(_ format: StreamFormat) {
        selectedFormat = format
        defaults.set(format.sampleRate, forKey: "sampleRate")
        defaults.set(format.bitDepth, forKey: "bitDepth")
        applyFormat()
    }

    /// Put the active format into effect: the device's sample rate and the bit depth the
    /// group streams, in the order `FormatSwitch` gives.
    private func applyFormat() {
        guard let format = activeFormat, let device = AudioDevice.sendspin else { return }
        let actions = formatSwitch.select(sampleRate: format.sampleRate, bitDepth: format.bitDepth,
                                          deviceRate: Int(device.nominalSampleRate))
        Task { await perform(actions) }
    }

    /// In order: the group hears of a bit depth before the rate it waits for changes.
    private func perform(_ actions: [FormatSwitch.Action]) async {
        for action in actions {
            switch action {
            case .setDeviceRate(let rate):
                do {
                    try AudioDevice.sendspin?.setNominalSampleRate(Double(rate))
                } catch {
                    Log.error("Couldn't switch the Sendspin device to \(rate) Hz: \(error)")
                    await perform(formatSwitch.deviceRateFailed())
                }
            case .setBitDepth(let bitDepth, let sampleRate):
                await group.setPreferredBitDepth(bitDepth, fromSampleRate: sampleRate)
            }
        }
    }

    func setLead(_ lead: Lead) {
        self.lead = lead
        defaults.set(lead.rawValue, forKey: "leadMs")
        applyLead()
    }

    /// The connected speaker that needs the most buffer, if it needs more than the setting.
    var leadRequirement: (name: String, ms: Int)? {
        let need = statuses.values.filter { $0.connection == .connected }
            .max { $0.requiredBufferMs < $1.requiredBufferMs }
        guard let need, need.requiredBufferMs > lead.rawValue else { return nil }
        return (need.name ?? "A speaker", need.requiredBufferMs)
    }

    /// The setting, raised to what connected speakers need: the spec requires keeping at
    /// least each player's min_buffer_ms + output_delay_ms queued.
    var effectiveLeadMs: Int { leadRequirement?.ms ?? lead.rawValue }

    private func applyLead() {
        let ms = effectiveLeadMs
        guard ms != appliedLeadMs else { return }
        appliedLeadMs = ms
        if let requirement = leadRequirement {
            Log.info("Speaker buffer \(ms) ms: \(requirement.name) needs more than the \(lead.rawValue) ms setting")
        }
        applyPresentationLatency()
        Task { await group.setLead(ms: ms) }
    }

    /// Report the lead as the device's output latency, so video players keep lip sync.
    /// Capture timestamps equal the output timestamps apps see (measured with
    /// `sendspin-bridge --measure-latency`), so the lead is the entire latency.
    private func applyPresentationLatency() {
        do {
            try AudioDevice.sendspin?.setPresentationLatency(microseconds: appliedLeadMs * 1000)
        } catch {
            Log.warning("Couldn't set presentation latency: \(error)")
        }
    }

    /// Make Sendspin the Mac's output, or switch back to the previous one. coreaudiod answers
    /// these calls and can be slow (it was busy for minutes after restarts), so they run off
    /// the main thread and the menu stays responsive.
    func setMacOutput(_ enabled: Bool) async {
        guard !isSwitchingOutput else { return }
        isSwitchingOutput = true
        defer { isSwitchingOutput = false }
        let previousUID = defaults.string(forKey: "previousOutputUID")
        apply(await Task.detached { Self.switchOutput(enabled, previousUID: previousUID) }.value)
    }

    /// Switch, then read back the new state. The output Sendspin replaces is remembered by
    /// `apply` before this runs, so switching back can find it.
    nonisolated private static func switchOutput(_ enabled: Bool, previousUID: String?) -> OutputState {
        if let sendspin = AudioDevice.sendspin {
            do {
                if enabled {
                    try AudioDevice.setDefaultOutput(sendspin)
                } else {
                    if let target = returnTarget(previousUID: previousUID) { try AudioDevice.setDefaultOutput(target) }
                }
            } catch {
                Log.error("Couldn't change the Mac's output: \(error)")
            }
        }
        return readOutput()
    }

    /// The output to leave Sendspin for: the previous one, or else the first other output.
    nonisolated private static func returnTarget(previousUID: String?) -> AudioDevice? {
        previousUID.flatMap(AudioDevice.find(uid:)) ?? AudioDevice.all().first {
            $0.uid != AudioDevice.sendspinUID && $0.channelCount(scope: kAudioObjectPropertyScopeOutput) > 0
        }
    }

    /// Install or update the driver. Returns false if the user cancelled.
    func installDriver() async throws -> Bool {
        isInstallingDriver = true
        defer { isInstallingDriver = false }
        // Restarting coreaudiod resets the default output: go back to Sendspin after an update.
        let wasMacOutput = isMacOutput
        guard try await DriverInstaller.install() else { return false }
        driverState = DriverInstaller.state
        // coreaudiod takes a moment to come back with the device.
        var appeared = false
        for _ in 0..<20 where !appeared {
            appeared = await Task.detached { AudioDevice.sendspin != nil }.value
            if !appeared { try? await Task.sleep(for: .milliseconds(500)) }
        }
        driverNeedsRestart = !appeared
        Log.info(appeared ? "Driver installed" : "Driver installed, but the device didn't appear")
        if appeared && wasMacOutput { await setMacOutput(true) }
        return true
    }

    /// Remove the driver and the app. Returns false if the user cancelled.
    func uninstall() async throws -> Bool {
        // Hand the Mac's sound back to the previous output before the device disappears.
        let wasMacOutput = isMacOutput
        if wasMacOutput { await setMacOutput(false) }
        let removed: Bool
        do {
            removed = try await Uninstaller.run()
        } catch {
            if wasMacOutput { await setMacOutput(true) }
            throw error
        }
        if !removed && wasMacOutput { await setMacOutput(true) }
        return removed
    }
}

/// A flag the capture pump reads for every block, off the main actor.
final class SpeakerRoute: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: true)

    var isOn: Bool { state.withLock { $0 } }

    func set(_ on: Bool) { state.withLock { $0 = on } }
}

extension PlayerStatus.Connection {
    /// The session stopped by itself and won't reconnect.
    var isFinal: Bool {
        switch self {
        case .taken, .disconnected, .pairingRequired, .notApproved: true
        default: false
        }
    }
}
