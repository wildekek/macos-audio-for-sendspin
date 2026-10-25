import Foundation

/// Audio output in a group that isn't a Sendspin player, such as this Mac's own speakers. It
/// gets the group's audio with each block's play time on the server clock, and keeps it in
/// sync with the players itself.
public protocol GroupOutput: AnyObject, Sendable {
    func play(_ pcm: PCMBuffer, timestampUs: Int64)
    /// The group stopped (idle, or its lead changed): drop what's queued.
    func stop()
}

/// A set of players that play the same live audio in sync.
///
/// Every chunk is scheduled at its capture time plus a fixed lead. Capture time comes
/// from the audio device's host-time stamps, so the timeline follows the capture clock
/// exactly: there is no drift to correct and no rebasing. Players that join late
/// simply start with the next chunk.
public actor PlaybackGroup {
    /// How long after its capture time a chunk can reach a player: the capture block, the
    /// FLAC encoder's block and the network. The lead must exceed what a player needs queued
    /// by this much, as its queue starts at the lead minus this (player/v1.md, Server Audio
    /// Send Constraints).
    public static let sendMarginMs = 50

    public nonisolated let id = UUID().uuidString
    public let name: String
    /// How far ahead of capture time players are told to play (their buffer).
    public private(set) var leadUs: Int64
    /// Bit depth to stream when players support it (16 or 24).
    public private(set) var preferredBitDepth = 16
    /// A bit depth that takes over with the first block at this rate.
    private var bitDepthForRate: (sampleRate: Int, bitDepth: Int)?

    private var sessions: [URL: (session: PlayerSession, task: Task<Void, Never>)] = [:]
    private var outputs: [ObjectIdentifier: any GroupOutput] = [:]
    private var playing = false
    private var lateChunks = 0
    /// Counts recomputations of the controller state, so an older one doesn't send late.
    private var controllerGeneration = 0

    public init(name: String, leadMs: Int) {
        self.name = name
        leadUs = Int64(leadMs) * 1_000
    }

    public var players: [PlayerSession] { sessions.values.map(\.session) }

    public var isPlaying: Bool { playing }

    /// Players switch format at the next chunk: each session restarts its stream. With
    /// `sampleRate`, the bit depth waits for the first block at that rate, so that a new rate
    /// and bit depth restart it once, together, however soon the blocks come.
    public func setPreferredBitDepth(_ bitDepth: Int, fromSampleRate sampleRate: Int? = nil) {
        if let sampleRate {
            bitDepthForRate = (sampleRate, bitDepth)
        } else {
            bitDepthForRate = nil
            preferredBitDepth = bitDepth
        }
    }

    /// Change the lead. Players restart their stream, since shifting timestamps
    /// mid-stream would make them skip or repeat audio.
    public func setLead(ms: Int) async {
        let newLead = Int64(ms) * 1_000
        guard newLead != leadUs else { return }
        let wasPlaying = playing
        await setPlaying(false)
        leadUs = newLead
        if wasPlaying { await setPlaying(true) }
    }

    /// Add a player; the group keeps it connected until it is removed.
    public func add(_ session: PlayerSession) async {
        guard sessions[session.url] == nil else { return }
        await session.join(groupID: id, groupName: name, group: self)
        await session.setPlaying(playing)
        sessions[session.url] = (session, Task { await session.run() })
    }

    public func remove(url: URL) async {
        guard let entry = sessions.removeValue(forKey: url) else { return }
        entry.task.cancel()
        await entry.session.shutdown()
        await membersChanged()
    }

    // MARK: Controller role (roles/controller/v1.md)

    /// A player's volume, mute or place in the group changed: send every controller its
    /// group's state, if that changed.
    func membersChanged() async {
        controllerGeneration += 1
        let generation = controllerGeneration
        var members: [(session: PlayerSession, member: ControllerMember)] = []
        for (session, _) in sessions.values { members.append((session, await session.controllerMember())) }
        let group = ControllerState(group: members.map(\.member).filter(\.inGroup))
        for (session, member) in members {
            guard generation == controllerGeneration else { return }
            // A player out of the group is a group of its own.
            await session.updateController(member.inGroup ? group : ControllerState(group: [member]))
        }
    }

    /// A controller's command for its group: ours, or the stopped group of its own it's in.
    func command(_ command: ControllerCommand, from controller: PlayerSession) async {
        var members: [(session: PlayerSession, member: ControllerMember)] = []
        for (session, _) in sessions.values { members.append((session, await session.controllerMember())) }
        guard let own = members.first(where: { $0.session === controller }) else { return }
        let targets = own.member.inGroup ? members.filter(\.member.inGroup) : [own]
        switch command.command {
        case "volume":
            guard let volume = command.volume else { return }
            // One command per player, after redistributing what one can't take (Setting group volume).
            let players = targets.filter { $0.member.canSetVolume && $0.member.volume != nil }
            let current = Dictionary(uniqueKeysWithValues: players.map { (ObjectIdentifier($0.session), $0.member.volume!) })
            let levels = GroupVolume.redistribute(current, to: volume)
            for player in players where levels[ObjectIdentifier(player.session)] != player.member.volume {
                await player.session.setVolume(levels[ObjectIdentifier(player.session)]!)
            }
        case "mute":
            guard let mute = command.mute else { return }
            for player in targets where player.member.canMute && player.member.muted != mute {
                await player.session.setMuted(mute)
            }
        default:
            return
        }
    }

    public func add(output: any GroupOutput) {
        outputs[ObjectIdentifier(output)] = output
    }

    public func remove(output: any GroupOutput) {
        outputs[ObjectIdentifier(output)]?.stop()
        outputs[ObjectIdentifier(output)] = nil
    }

    /// Fan one captured block out to all players.
    /// - Parameter captureTimeUs: server-clock time of the block's first sample.
    public func push(_ pcm: PCMBuffer, captureTimeUs: Int64) async {
        if let waiting = bitDepthForRate, pcm.sampleRate == waiting.sampleRate {
            preferredBitDepth = waiting.bitDepth
            bitDepthForRate = nil
        }
        if !playing { await setPlaying(true) }
        let timestampUs = captureTimeUs + leadUs
        // Chunks that would arrive after their play time are useless to every player.
        if timestampUs < ServerClock.nowMicros() + 20_000 {
            lateChunks += 1
            if lateChunks.isMultiple(of: 50) { Log.warning("dropped \(lateChunks) late chunks") }
            return
        }
        for output in outputs.values {
            output.play(pcm, timestampUs: timestampUs)
        }
        for (session, _) in sessions.values {
            await session.deliver(pcm, timestampUs: timestampUs, preferredBitDepth: preferredBitDepth, leadUs: leadUs)
        }
    }

    /// Mark the group idle: players get `stream/end` and `group/update` stopped.
    public func setPlaying(_ playing: Bool) async {
        guard playing != self.playing else { return }
        self.playing = playing
        for (session, _) in sessions.values {
            await session.setPlaying(playing)
        }
        if !playing {
            for output in outputs.values { output.stop() }
        }
    }

    public func shutdown() async {
        for url in Array(sessions.keys) {
            await remove(url: url)
        }
        for output in Array(outputs.values) {
            remove(output: output)
        }
    }
}
