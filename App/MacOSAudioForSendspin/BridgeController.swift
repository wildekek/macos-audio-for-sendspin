import AVFoundation
import CoreAudio
import Foundation
import Observation
import SendspinAudio
import SendspinServerKit
import os

/// Owns the bridge: discovers players, keeps the selected ones in one group, captures
/// the Sendspin device and streams it, and links the device's volume/mute (volume keys,
/// Control Center) with the players.
@MainActor
@Observable
final class BridgeController {
    struct Player: Identifiable {
        var id: String { instanceName }
        var instanceName: String
        var name: String
        var isSelected: Bool
        var status: PlayerStatus?
        var isDiscovered: Bool
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
    private(set) var isStreaming = false
    private(set) var driverInstalled = false
    private(set) var microphoneAccess = AVCaptureDevice.authorizationStatus(for: .audio)
    private(set) var isMacOutput = false
    private(set) var isSwitchingOutput = false
    private(set) var deviceVolume: Float = 1
    private(set) var deviceMuted = false
    private(set) var lead: Lead
    /// The lead the group and the device latency currently use (see `effectiveLeadMs`).
    private var appliedLeadMs: Int
    /// The format chosen in the menu; `activeFormat` is what's applied.
    private(set) var selectedFormat: StreamFormat
    private(set) var deviceSampleRate = 48_000
    private var deviceSampleRates: Set<Int> = []

    var players: [Player] {
        var names = Set(discovered.map(\.instanceName)).union(selected)
        names.formUnion(statuses.keys)
        return names.sorted().map { name in
            let discovery = discovered.first { $0.instanceName == name }
            return Player(instanceName: name,
                          name: statuses[name]?.name ?? discovery?.displayName ?? name,
                          isSelected: selected.contains(name),
                          status: statuses[name],
                          isDiscovered: discovery != nil)
        }
    }

    var hasConnectedPlayers: Bool { statuses.values.contains { $0.connection == .connected } }

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
    private var sessions: [String: PlayerSession] = [:]
    private var capture: AudioCapture?
    private var pumpTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var systemObservations: [PropertyObservation] = []
    private var deviceObservations: [PropertyObservation] = []
    /// Volume we just wrote to the device ourselves; its change notification is not a user action.
    private var expectedDeviceVolume: Float?

    init() {
        let defaults = UserDefaults.standard
        let lead = Lead(rawValue: defaults.integer(forKey: "leadMs")) ?? .low
        // The pre-1.0 server ID; Sendspin 1 identifies the server by its Noise key.
        defaults.removeObject(forKey: "serverID")
        let identity = IdentityStore.load(name: Host.current().localizedName ?? "Mac")
        selected = Set(defaults.stringArray(forKey: "selectedPlayers") ?? [])
        selectedFormat = StreamFormat(sampleRate: defaults.object(forKey: "sampleRate") as? Int ?? 48_000,
                                      bitDepth: defaults.object(forKey: "bitDepth") as? Int ?? 16)
        self.lead = lead
        appliedLeadMs = lead.rawValue
        self.identity = identity
        group = PlaybackGroup(name: identity.name, leadMs: lead.rawValue)

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
        discoveryTask = Task { [weak self] in
            for await players in PlayerBrowser.browse() {
                guard let self else { return }
                Log.debug("Discovered: \(players.map { "\($0.instanceName) \($0.url.absoluteString)" })")
                discovered = players + manualPlayers()
                reconcile()
            }
        }
        // Don't hold up discovery and connecting on the permission prompt.
        if microphoneAccess == .notDetermined {
            microphoneAccess = await AVCaptureDevice.requestAccess(for: .audio) ? .authorized : .denied
            Log.info("Microphone access \(microphoneAccess == .authorized ? "granted" : "denied")")
            updateCapture()
        }
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
            // Re-selecting a player that left or was taken over reconnects it.
            if let status = statuses[instanceName], status.connection.isFinal { dropSession(instanceName) }
        } else {
            selected.remove(instanceName)
            // Unticking withdraws the approval; ticking again approves whatever identity shows up.
            var approved = approvedPlayers
            approved[instanceName] = nil
            defaults.set(approved, forKey: "approvedPlayers")
        }
        defaults.set(Array(selected), forKey: "selectedPlayers")
        reconcile()
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
        for (name, session) in sessions {
            // Drop deselected players, and players that moved to another address.
            let currentURL = discovered.first { $0.instanceName == name }?.url
            if !selected.contains(name) || (currentURL != nil && currentURL != session.url) {
                dropSession(name)
            }
        }
        for player in discovered where selected.contains(player.instanceName) && sessions[player.instanceName] == nil {
            addSession(for: player)
        }
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

    private func playerStatusChanged(_ name: String, _ status: PlayerStatus) {
        guard sessions[name] != nil else { return }
        let formatsChanged = statuses[name]?.supportedFormats != status.supportedFormats
            || statuses[name]?.connection != status.connection
        statuses[name] = status
        syncDeviceToPlayers()
        applyLead()
        if formatsChanged { applyFormat() }
    }

    // MARK: Capture

    private func updateCapture() {
        let wanted = !sessions.isEmpty && microphoneAccess == .authorized
        if wanted, capture == nil, let device = AudioDevice.sendspin {
            // Capture at the device's own rate: no conversion before the speakers.
            do {
                let capture = try AudioCapture(device: device)
                try capture.start()
                self.capture = capture
                let streamingChanged: @Sendable (Bool) async -> Void = { [weak self] streaming in
                    await self?.setStreaming(streaming)
                }
                pumpTask = Task.detached { [group] in
                    await Self.pump(capture.blocks, into: group, streamingChanged: streamingChanged)
                }
                Log.info("Capturing from \(capture.deviceName) at \(capture.sampleRate) Hz")
            } catch {
                Log.error("Capture failed: \(error)")
            }
        } else if !wanted, capture != nil {
            stopCapture()
            isStreaming = false
            Task { await group.setPlaying(false) }
            Log.info("Capture stopped")
        }
    }

    private func stopCapture() {
        pumpTask?.cancel()
        capture?.stop()
        capture = nil
    }

    /// The device switched sample rate (from us, or e.g. Audio MIDI Setup): capture at
    /// the new rate. Players get a new stream/start in their (possibly new) format.
    private func deviceSampleRateChanged() {
        guard let rate = AudioDevice.sendspin.map({ Int($0.nominalSampleRate) }), rate != deviceSampleRate else { return }
        Log.info("Sendspin device now runs at \(rate) Hz")
        deviceSampleRate = rate
        applyPresentationLatency()
        if capture != nil {
            stopCapture()
            updateCapture()
        }
    }

    private func setStreaming(_ streaming: Bool) {
        isStreaming = streaming
    }

    /// Forward captured audio; after a few seconds of digital silence the players get
    /// `stream/end`, and the stream restarts with the next sound.
    nonisolated private static func pump(_ blocks: AsyncStream<CapturedBlock>, into group: PlaybackGroup,
                                         streamingChanged: @Sendable (Bool) async -> Void) async {
        let idleAfterUs: Int64 = 3_000_000
        var lastSoundUs: Int64?
        var streaming = false
        for await block in blocks {
            if !block.pcm.isSilent { lastSoundUs = block.captureTimeUs }
            let active = lastSoundUs.map { block.captureTimeUs - $0 < idleAfterUs } ?? false
            if active {
                await group.push(block.pcm, captureTimeUs: block.captureTimeUs)
            } else if streaming {
                await group.setPlaying(false)
            }
            if active != streaming {
                streaming = active
                await streamingChanged(active)
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
        let device = AudioDevice.sendspin
        driverInstalled = device != nil
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
        isMacOutput = AudioDevice.defaultOutput?.uid == AudioDevice.sendspinUID
    }

    /// Volume keys / Control Center / our group slider changed the device volume.
    private func deviceVolumeChanged() {
        guard let volume = AudioDevice.sendspin?.volume else { return }
        deviceVolume = volume
        if let expected = expectedDeviceVolume, abs(expected - volume) < 0.005 {
            expectedDeviceVolume = nil
            return
        }
        let current = connectedVolumes()
        let target = Int((volume * 100).rounded())
        guard GroupVolume.level(current) != target else { return }
        for (name, level) in GroupVolume.redistribute(current, to: target) where current[name] != level {
            Task { await sessions[name]?.setVolume(level) }
        }
    }

    private func deviceMuteChanged() {
        guard let muted = AudioDevice.sendspin?.isMuted, muted != deviceMuted else { return }
        deviceMuted = muted
        let targets = sessions.filter { statuses[$0.key]?.muted != muted }.map(\.value)
        for session in targets {
            Task { await session.setMuted(muted) }
        }
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

    func setGroupVolume(_ volume: Float) {
        AudioDevice.sendspin?.volume = volume
    }

    func setGroupMuted(_ muted: Bool) {
        AudioDevice.sendspin?.isMuted = muted
    }

    func setPlayerVolume(_ instanceName: String, _ volume: Int) {
        Task { await sessions[instanceName]?.setVolume(volume) }
    }

    func selectFormat(_ format: StreamFormat) {
        selectedFormat = format
        defaults.set(format.sampleRate, forKey: "sampleRate")
        defaults.set(format.bitDepth, forKey: "bitDepth")
        applyFormat()
    }

    /// Put the active format into effect: the device's sample rate (capture follows via
    /// `deviceSampleRateChanged`) and the bit depth the group streams.
    private func applyFormat() {
        guard let format = activeFormat, let device = AudioDevice.sendspin else { return }
        if Int(device.nominalSampleRate) != format.sampleRate {
            do {
                try device.setNominalSampleRate(Double(format.sampleRate))
            } catch {
                Log.error("Couldn't switch the Sendspin device to \(format.sampleRate) Hz: \(error)")
            }
        }
        Task { await group.setPreferredBitDepth(format.bitDepth) }
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
            try AudioDevice.sendspin?.setPresentationLatency(frames: appliedLeadMs * deviceSampleRate / 1000)
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
        let result = await Task.detached { Self.switchOutput(enabled, previousUID: previousUID) }.value
        if let uid = result.replacedUID {
            defaults.set(uid, forKey: "previousOutputUID")
        }
        isMacOutput = result.isMacOutput
    }

    /// Returns the output Sendspin replaced (to switch back to later) and the new state.
    nonisolated private static func switchOutput(_ enabled: Bool, previousUID: String?)
        -> (replacedUID: String?, isMacOutput: Bool) {
        var replacedUID: String?
        if let sendspin = AudioDevice.sendspin {
            do {
                if enabled {
                    if let current = AudioDevice.defaultOutput, current.uid != AudioDevice.sendspinUID {
                        replacedUID = current.uid
                    }
                    try AudioDevice.setDefaultOutput(sendspin)
                } else {
                    let previous = previousUID.flatMap(AudioDevice.find(uid:))
                    let fallback = AudioDevice.all().first {
                        $0.uid != AudioDevice.sendspinUID && $0.channelCount(scope: kAudioObjectPropertyScopeOutput) > 0
                    }
                    if let target = previous ?? fallback { try AudioDevice.setDefaultOutput(target) }
                }
            } catch {
                Log.error("Couldn't change the Mac's output: \(error)")
            }
        }
        return (replacedUID, AudioDevice.defaultOutput?.uid == AudioDevice.sendspinUID)
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

extension PlayerStatus.Connection {
    /// The session stopped by itself and won't reconnect.
    var isFinal: Bool {
        switch self {
        case .taken, .disconnected, .pairingRequired, .notApproved: true
        default: false
        }
    }
}
