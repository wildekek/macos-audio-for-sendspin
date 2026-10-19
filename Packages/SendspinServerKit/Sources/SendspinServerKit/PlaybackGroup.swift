import Foundation

/// A set of players that play the same live audio in sync.
///
/// Every chunk is scheduled at its capture time plus a fixed lead. Capture time comes
/// from the audio device's host-time stamps, so the timeline follows the capture clock
/// exactly: there is no drift to correct and no rebasing. Players that join late
/// simply start with the next chunk.
public actor PlaybackGroup {
    public nonisolated let id = UUID().uuidString
    public let name: String
    /// How far ahead of capture time players are told to play (their buffer).
    public private(set) var leadUs: Int64
    /// Bit depth to stream when players support it (16 or 24).
    public private(set) var preferredBitDepth = 16

    private var sessions: [URL: (session: PlayerSession, task: Task<Void, Never>)] = [:]
    private var playing = false
    private var lateChunks = 0

    public init(name: String, leadMs: Int) {
        self.name = name
        leadUs = Int64(leadMs) * 1_000
    }

    public var players: [PlayerSession] { sessions.values.map(\.session) }

    public var isPlaying: Bool { playing }

    public func setPreferredBitDepth(_ bitDepth: Int) {
        // Players switch format at the next chunk (each session restarts its stream).
        preferredBitDepth = bitDepth
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
        await session.join(groupID: id, groupName: name)
        await session.setPlaying(playing)
        sessions[session.url] = (session, Task { await session.run() })
    }

    public func remove(url: URL) async {
        guard let entry = sessions.removeValue(forKey: url) else { return }
        entry.task.cancel()
        await entry.session.shutdown()
    }

    /// Fan one captured block out to all players.
    /// - Parameter captureTimeUs: server-clock time of the block's first sample.
    public func push(_ pcm: PCMBuffer, captureTimeUs: Int64) async {
        if !playing { await setPlaying(true) }
        let timestampUs = captureTimeUs + leadUs
        // Chunks that would arrive after their play time are useless to every player.
        if timestampUs < ServerClock.nowMicros() + 20_000 {
            lateChunks += 1
            if lateChunks.isMultiple(of: 50) { Log.warning("dropped \(lateChunks) late chunks") }
            return
        }
        for (session, _) in sessions.values {
            await session.deliver(pcm, timestampUs: timestampUs, preferredBitDepth: preferredBitDepth)
        }
    }

    /// Mark the group idle: players get `stream/end` and `group/update` stopped.
    public func setPlaying(_ playing: Bool) async {
        guard playing != self.playing else { return }
        self.playing = playing
        for (session, _) in sessions.values {
            await session.setPlaying(playing)
        }
    }

    public func shutdown() async {
        for url in Array(sessions.keys) {
            await remove(url: url)
        }
    }
}
