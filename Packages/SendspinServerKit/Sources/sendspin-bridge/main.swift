import Foundation
import SendspinAudio
import SendspinServerKit

let usage = """
    usage: sendspin-bridge [options] <player>...
           sendspin-bridge --list
           sendspin-bridge --measure-latency | --check-loopback | --check-rate-switch
           sendspin-bridge --cycle-formats RATE/BITS,... [--every S] <player>...
           sendspin-bridge --measure-sync [--mic NAME]
           sendspin-bridge --source [--tone] [--device NAME]

    Stream audio from an input device (default: the Sendspin device) to Sendspin players.
    A player is an mDNS instance name (or substring) or a ws:// URL.

    options:
      --list            list Sendspin players on the network and exit
      --measure-latency measure capture vs. output timestamps on the Sendspin device and exit
      --check-loopback  check that the Sendspin driver hands back its audio sample-exact
      --check-rate-switch check that each sample-rate switch restarts the device's timeline
                        once and keeps the latency apps see
      --cycle-formats LIST stream the Sendspin device to the players and switch it through
                        these formats in turn (e.g. 48000/16,96000/24), as the app does
      --every S         seconds per format for --cycle-formats (default: 3)
      --source          be a Sendspin source instead (source@v1 client): advertise as
                        _sendspin._tcp, print the pairing token for Music Assistant, and
                        stream the audio to the server that pairs and asks for it
      --measure-sync    measure lip sync acoustically: play chirps into the Sendspin device
                        (the app must be streaming to the speakers) and listen with a mic
      --mic NAME        microphone for --measure-sync (default: the default input)
      --output NAME     play the chirps on this device instead of Sendspin (validates the
                        probe itself: e.g. "MacBook Pro Speakers" should give ~0 ms error)
      --device NAME     input device name or substring (default: Sendspin)
      --tone            send a 440 Hz test tone (-20 dBFS) instead of capturing
      --lead-ms N       playback lead / player buffer in ms (default: 1000)
      --name NAME       server name shown to players (default: Sendspin Bridge)
      -v, --verbose     debug logging
    """

struct Options {
    var list = false
    var measureLatency = false
    var checkLoopback = false
    var checkRateSwitch = false
    var cycleFormats: [(sampleRate: Int, bitDepth: Int)]?
    var everySeconds = 3.0
    var measureSync = false
    var source = false
    var microphone: String?
    var output: String?
    var device = "Sendspin"
    var tone = false
    var leadMs = 1000
    var name = "Sendspin Bridge"
    var players: [String] = []
}

func parseOptions() -> Options {
    var options = Options()
    var args = CommandLine.arguments.dropFirst()
    func value(for flag: String) -> String {
        guard let value = args.popFirst() else { fail("\(flag) needs a value") }
        return value
    }
    while let arg = args.popFirst() {
        switch arg {
        case "--list": options.list = true
        case "--measure-latency": options.measureLatency = true
        case "--check-loopback": options.checkLoopback = true
        case "--check-rate-switch": options.checkRateSwitch = true
        case "--cycle-formats":
            let formats = value(for: arg).split(separator: ",").map { item -> (sampleRate: Int, bitDepth: Int) in
                let parts = item.split(separator: "/").compactMap { Int($0) }
                guard parts.count == 2, [16, 24].contains(parts[1]) else { fail("--cycle-formats wants RATE/BITS,…") }
                return (parts[0], parts[1])
            }
            guard !formats.isEmpty else { fail("--cycle-formats wants RATE/BITS,…") }
            options.cycleFormats = formats
        case "--every":
            guard let seconds = Double(value(for: arg)), seconds > 0 else { fail("--every needs a positive number") }
            options.everySeconds = seconds
        case "--measure-sync": options.measureSync = true
        case "--source": options.source = true
        case "--mic": options.microphone = value(for: arg)
        case "--output": options.output = value(for: arg)
        case "--device": options.device = value(for: arg)
        case "--tone": options.tone = true
        case "--lead-ms":
            guard let ms = Int(value(for: arg)), ms > 0 else { fail("--lead-ms needs a positive number") }
            options.leadMs = ms
        case "--name": options.name = value(for: arg)
        case "-v", "--verbose": Log.minimumLevel = .debug
        case "-h", "--help": print(usage); exit(0)
        default:
            if arg.hasPrefix("-") { fail("unknown option \(arg)") }
            options.players.append(arg)
        }
    }
    if !options.list && !options.measureLatency && !options.checkLoopback && !options.checkRateSwitch && !options.measureSync && !options.source && options.players.isEmpty { fail("give at least one player (use --list)") }
    return options
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n\n\(usage)\n".utf8))
    exit(2)
}

/// A stable server id, so players see the same server across restarts.
/// The server's Noise identity, kept across runs so players see the same server.
func loadIdentity(name: String) -> ServerIdentity {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/sendspin-bridge")
    let file = dir.appending(path: "server-key")
    if let text = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
       let key = Data(base64Encoded: text), let identity = try? ServerIdentity(privateKeyData: key, name: name) {
        return identity
    }
    let identity = ServerIdentity.generate(name: name)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // The private key: readable by this user only.
    FileManager.default.createFile(atPath: file.path, contents: Data(identity.privateKeyData.base64EncodedString().utf8),
                                   attributes: [.posixPermissions: 0o600])
    return identity
}

func resolvePlayers(_ queries: [String]) async -> [URL] {
    var urls = queries.compactMap { $0.hasPrefix("ws://") ? URL(string: $0) : nil }
    let names = queries.filter { !$0.hasPrefix("ws://") }
    guard !names.isEmpty else { return urls }

    let discovered = await PlayerBrowser.discover()
    for name in names {
        let matches = discovered.filter { $0.instanceName.localizedCaseInsensitiveContains(name) }
        guard matches.count == 1 else {
            let known = discovered.map(\.instanceName).joined(separator: ", ")
            fail("player \"\(name)\" matched \(matches.count) players (discovered: \(known.isEmpty ? "none" : known))")
        }
        urls.append(matches[0].url)
    }
    return urls
}

func run() async {
    let options = parseOptions()

    if options.list {
        let players = await PlayerBrowser.discover()
        if players.isEmpty { print("No Sendspin players found") }
        for player in players {
            print("\(player.instanceName)\t\(player.url.absoluteString)")
        }
        return
    }

    if options.measureLatency {
        do {
            guard let device = AudioDevice.sendspin else { fail("the Sendspin device isn't installed") }
            print("Measuring on \(device.name ?? "?") (keep other audio off this device)…")
            let result = try await LoopbackLatencyProbe.measure(device: device)
            let ms = result.offsetsUs.map { String(format: "%.2f", Double($0) / 1000) }
            print("clicks played \(result.clicksPlayed), detected \(result.offsetsUs.count)")
            print("capture − output offsets (ms): \(ms.joined(separator: " "))")
            if let median = result.medianUs {
                print(String(format: "median offset: %.2f ms", Double(median) / 1000))
            }
            // Capture timestamps should be the output timestamps apps see.
            let passed = result.medianUs.map { abs($0) < 1_000 } ?? false
            print(passed ? "PASS" : "FAIL")
            exit(passed ? 0 : 1)
        } catch {
            fail("\(error)")
        }
    }

    if options.checkLoopback {
        await checkLoopback()
        return
    }

    if options.checkRateSwitch {
        await checkRateSwitch()
        return
    }

    if options.measureSync {
        await measureSync(options)
        return
    }

    if options.source {
        await runSource(options)
        return
    }

    let urls = await resolvePlayers(options.players)
    if let formats = options.cycleFormats {
        await cycleFormats(formats, urls: urls, options: options)
        return
    }
    let (source, stopCapture) = audioSource(options)

    let identity = loadIdentity(name: options.name)
    let group = PlaybackGroup(name: options.name, leadMs: options.leadMs)
    for url in urls {
        // Players named on the command line are the user's explicit choice: approved.
        let session = PlayerSession(url: url, identity: identity, approve: { _ in true })
        Task {
            var bufferWarned = false
            for await status in session.updates {
                Log.info("\(status.name ?? url.absoluteString): \(status.connection)"
                    + (status.volume.map { ", volume \($0)" } ?? "")
                    + (status.muted == true ? ", muted" : ""))
                if status.requiredBufferMs > options.leadMs, !bufferWarned {
                    bufferWarned = true
                    Log.warning("\(status.name ?? url.absoluteString) needs \(status.requiredBufferMs) ms of buffer; "
                        + "use --lead-ms \(status.requiredBufferMs) or more")
                }
            }
        }
        Log.info("Connecting to \(url.absoluteString)")
        await group.add(session)
    }

    let pump = Task {
        for await block in source {
            await group.push(block.pcm, captureTimeUs: block.captureTimeUs)
        }
    }

    for await _ in stopSignal() { break }

    Log.info("Shutting down")
    pump.cancel()
    stopCapture()
    await group.shutdown()
    try? await Task.sleep(for: .milliseconds(200))
}

/// The audio to stream: the test tone, the Sendspin device (read from its driver), or another
/// input device. Comes with what stops it.
func audioSource(_ options: Options) -> (AsyncStream<CapturedBlock>, @Sendable () -> Void) {
    if options.tone {
        Log.info("Audio: 440 Hz test tone")
        return (ToneSource.blocks(), {})
    }
    do {
        if let sendspin = AudioDevice.sendspin, sendspin.name?.localizedCaseInsensitiveContains(options.device) == true {
            let capture = try DriverCapture(device: sendspin)
            try capture.start()
            Log.info("Audio: \(capture.deviceName) (from its driver), \(capture.sampleRate) Hz float stereo")
            return (capture.blocks, capture.stop)
        }
        let capture = try AudioCapture(deviceName: options.device)
        try capture.start()
        Log.info("Audio: \(capture.deviceName), \(capture.sampleRate) Hz float stereo")
        return (capture.blocks, capture.stop)
    } catch {
        fail("\(error)")
    }
}

func checkRateSwitch() async {
    guard let device = AudioDevice.sendspin else { fail("the Sendspin device isn't installed") }
    print("Switching \(device.name ?? "Sendspin") through its sample rates (keep the app quit)…")
    do {
        let result = try await RateSwitchCheck.run(device: device)
        for change in result.switches {
            print(String(format: "%6d Hz: %d timeline restart(s), latency %.1f ms, captured at %@ — %@",
                         change.sampleRate, change.timelineRestarts, Double(change.reportedLatencyUs) / 1000,
                         change.capturedRate.map { "\($0) Hz" } ?? "nothing",
                         change.passed(latencyUs: result.latencyUs) ? "ok" : "FAIL"))
        }
        print(result.passed ? "PASS" : "FAIL")
        exit(result.passed ? 0 : 1)
    } catch {
        fail("\(error)")
    }
}

/// Stream the Sendspin device to the players while switching it through `formats`, each
/// applied as the app applies a choice in Settings (`FormatSwitch`), so a test player can
/// check what a switch does to the stream. The first format is in place before players join.
func cycleFormats(_ formats: [(sampleRate: Int, bitDepth: Int)], urls: [URL], options: Options) async {
    guard let device = AudioDevice.sendspin else { fail("the Sendspin device isn't installed") }
    let originalRate = device.nominalSampleRate
    let capture: DriverCapture
    do {
        capture = try DriverCapture(device: device)
        try capture.start()
    } catch {
        fail("\(error)")
    }
    let group = PlaybackGroup(name: options.name, leadMs: options.leadMs)
    let pump = Task {
        for await block in capture.blocks {
            await group.push(block.pcm, captureTimeUs: block.captureTimeUs)
        }
    }

    var formatSwitch = FormatSwitch()
    await apply(formats[0], device: device, group: group, formatSwitch: &formatSwitch)
    let identity = loadIdentity(name: options.name)
    for url in urls {
        await group.add(PlayerSession(url: url, identity: identity, approve: { _ in true }))
    }
    try? await Task.sleep(for: .seconds(options.everySeconds))
    for format in formats.dropFirst() {
        Log.info("Switching to \(format.sampleRate) Hz \(format.bitDepth)-bit")
        await apply(format, device: device, group: group, formatSwitch: &formatSwitch)
        try? await Task.sleep(for: .seconds(options.everySeconds))
    }

    pump.cancel()
    capture.stop()
    await group.shutdown()
    try? device.setNominalSampleRate(originalRate)
    try? await Task.sleep(for: .milliseconds(200))
}

/// Apply one format, waiting for a new rate to land before what waited for it.
func apply(_ format: (sampleRate: Int, bitDepth: Int), device: AudioDevice, group: PlaybackGroup,
           formatSwitch: inout FormatSwitch) async {
    var actions = formatSwitch.select(sampleRate: format.sampleRate, bitDepth: format.bitDepth,
                                      deviceRate: Int(device.nominalSampleRate))
    while !actions.isEmpty {
        var next: [FormatSwitch.Action] = []
        for action in actions {
            switch action {
            case .setDeviceRate(let rate):
                do {
                    try device.setNominalSampleRate(Double(rate))
                    for _ in 0..<30 where Int(device.nominalSampleRate) != rate {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    next += Int(device.nominalSampleRate) == rate
                        ? formatSwitch.deviceRateChanged() : formatSwitch.deviceRateFailed()
                } catch {
                    Log.error("Couldn't switch the Sendspin device to \(rate) Hz: \(error)")
                    next += formatSwitch.deviceRateFailed()
                }
            case .setBitDepth(let bitDepth):
                await group.setPreferredBitDepth(bitDepth)
            }
        }
        actions = next
    }
}

func checkLoopback() async {
    guard let device = AudioDevice.sendspin else { fail("the Sendspin device isn't installed") }
    print("Playing noise into \(device.name ?? "Sendspin") (keep other audio off this device)…")
    do {
        let result = try await LoopbackCheck.run(device: device)
        print("\(result.signalFrames) frames at \(result.sampleRate) Hz: "
            + (result.mismatchedFrames == 0 ? "sample-exact" : "\(result.mismatchedFrames) frames differ or are missing"))
        print(result.framesAfterBurst == 0 ? "silence after the burst" : "\(result.framesAfterBurst) non-silent frames after the burst")
        if let offset = result.offsetUs {
            print(String(format: "capture − output offset: %.2f ms", Double(offset) / 1000))
        }
        print(result.passed ? "PASS" : "FAIL")
        exit(result.passed ? 0 : 1)
    } catch {
        fail("\(error)")
    }
}

/// Ctrl-C / SIGTERM, so peers get a clean goodbye.
func stopSignal() -> AsyncStream<Void> {
    AsyncStream { continuation in
        let sources = [SIGINT, SIGTERM].map { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { continuation.yield() }
            source.resume()
            return source
        }
        // Keep the sources alive for the lifetime of the stream.
        continuation.onTermination = { _ in sources.forEach { $0.cancel() } }
    }
}

/// The client credentials, kept across runs so a paired server stays paired.
func loadSourceCredentials() -> (SourceCredentials, @Sendable (SourceCredentials) -> Void) {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/sendspin-bridge")
    let file = dir.appending(path: "source-credentials.json")
    let save: @Sendable (SourceCredentials) -> Void = { credentials in
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Secrets: readable by this user only.
        FileManager.default.createFile(atPath: file.path, contents: try? JSONEncoder().encode(credentials),
                                       attributes: [.posixPermissions: 0o600])
    }
    if let data = try? Data(contentsOf: file), let credentials = try? JSONDecoder().decode(SourceCredentials.self, from: data) {
        return (credentials, save)
    }
    let credentials = SourceCredentials.generate()
    save(credentials)
    return (credentials, save)
}

func runSource(_ options: Options) async {
    let (source, stopCapture) = audioSource(options)
    let (credentials, save) = loadSourceCredentials()
    let client = SourceClient(name: options.name, softwareVersion: "sendspin-bridge", credentials: credentials, save: save)
    print("Pairing token: \(client.pairingToken)")
    await client.start()
    await client.setAvailable(true)
    let statusTask = Task {
        var shownCode: String?
        for await status in client.statusUpdates {
            Log.info("Source: \(status.serverName.map { "\($0), \(status.paired ? "paired" : "not paired")" } ?? "no server")"
                + (status.streaming ? ", streaming" : "") + (status.advertisedName.map { " (advertised as \($0))" } ?? ""))
            // The terminal is this tool's display for the dynamic pairing code.
            if status.pairingCode != shownCode {
                shownCode = status.pairingCode
                if let code = shownCode { print("Pairing code: \(code.prefix(3))-\(code.suffix(3))") }
            }
        }
    }
    let pump = Task {
        for await block in source {
            await client.deliver(block.pcm, captureTimeUs: block.captureTimeUs, bitDepth: 16)
        }
    }
    for await _ in stopSignal() { break }
    Log.info("Shutting down")
    pump.cancel()
    statusTask.cancel()
    stopCapture()
    await client.stop()
    try? await Task.sleep(for: .milliseconds(200))
}

/// Output to play chirps on (default: Sendspin) and microphone to listen with.
func syncDevices(_ options: Options) throws -> (AudioDevice, AudioDevice) {
    guard let output = try options.output.map(AudioDevice.output(matching:)) ?? AudioDevice.sendspin else {
        fail("the Sendspin device isn't installed")
    }
    let microphone = try options.microphone.map(AudioDevice.input(matching:)) ?? AudioDevice.defaultInput
    guard let microphone else { fail("no microphone") }
    return (output, microphone)
}

func measureSync(_ options: Options) async {
    func ms(_ us: Int64) -> String { String(format: "%.1f ms", Double(us) / 1000) }
    do {
        let (output, microphone) = try syncDevices(options)
        print("Playing chirps into \(output.name ?? "Sendspin"), listening on \(microphone.name ?? "?")…")
        print("(The app must be streaming to the speakers; pause other audio.)")
        let result = try await AcousticSyncProbe.measure(output: output, microphone: microphone)
        for (i, m) in result.measurements.enumerated() {
            print("  chirp \(i + 1): heard \(ms(m.delayUs)) after its render time (similarity \(String(format: "%.2f", m.similarity)))")
        }
        print("chirps played \(result.chirpsPlayed), heard \(result.measurements.count)")
        print("reported output latency \(ms(result.reportedOutputLatencyUs)), microphone input latency \(ms(result.microphoneLatencyUs))")
        if let delay = result.medianDelayUs, let error = result.syncErrorUs {
            print("median acoustic delay \(ms(delay)) → sync error \(error >= 0 ? "+" : "")\(ms(error))"
                + " (positive: sound later than the picture; includes ~2.9 ms per metre to the mic)")
        } else {
            print("no chirps detected: is the app streaming, the speaker audible, and the mic allowed?")
        }
    } catch {
        fail("\(error)")
    }
}

// Line-buffer stdout, so progress shows up promptly when it's redirected to a file.
setvbuf(stdout, nil, _IOLBF, 0)

await run()
