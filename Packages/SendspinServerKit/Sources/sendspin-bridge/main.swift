import Foundation
import SendspinAudio
import SendspinServerKit

let usage = """
    usage: sendspin-bridge [options] <player>...
           sendspin-bridge --list
           sendspin-bridge --measure-latency [--device NAME]
           sendspin-bridge --measure-sync [--mic NAME]

    Stream audio from an input device (default: the Sendspin device) to Sendspin players.
    A player is an mDNS instance name (or substring) or a ws:// URL.

    options:
      --list            list Sendspin players on the network and exit
      --measure-latency measure capture vs. output timestamps on the device and exit
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
    var measureSync = false
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
        case "--measure-sync": options.measureSync = true
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
    if !options.list && !options.measureLatency && !options.measureSync && options.players.isEmpty { fail("give at least one player (use --list)") }
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
            let device = try AudioDevice.input(matching: options.device)
            print("Measuring on \(device.name ?? "?") (keep other audio off this device)…")
            let result = try await LoopbackLatencyProbe.measure(device: device)
            let ms = result.offsetsUs.map { String(format: "%.2f", Double($0) / 1000) }
            print("clicks played \(result.clicksPlayed), detected \(result.offsetsUs.count)")
            print("capture − output offsets (ms): \(ms.joined(separator: " "))")
            if let median = result.medianUs {
                print(String(format: "median offset: %.2f ms", Double(median) / 1000))
            }
        } catch {
            fail("\(error)")
        }
        return
    }

    if options.measureSync {
        await measureSync(options)
        return
    }

    let urls = await resolvePlayers(options.players)

    let source: AsyncStream<CapturedBlock>
    var capture: AudioCapture?
    if options.tone {
        Log.info("Source: 440 Hz test tone")
        source = ToneSource.blocks()
    } else {
        do {
            let deviceCapture = try AudioCapture(deviceName: options.device)
            try deviceCapture.start()
            Log.info("Source: \(deviceCapture.deviceName), \(deviceCapture.sampleRate) Hz float stereo")
            source = deviceCapture.blocks
            capture = deviceCapture
        } catch {
            fail("\(error)")
        }
    }

    let identity = loadIdentity(name: options.name)
    let group = PlaybackGroup(name: options.name, leadMs: options.leadMs)
    for url in urls {
        // Players named on the command line are the user's explicit choice: approved.
        let session = PlayerSession(url: url, identity: identity, approve: { _ in true })
        Task {
            for await status in session.updates {
                Log.info("\(status.name ?? url.absoluteString): \(status.connection)"
                    + (status.volume.map { ", volume \($0)" } ?? "")
                    + (status.muted == true ? ", muted" : ""))
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

    // Shut down cleanly on Ctrl-C / SIGTERM so players get stream/end.
    let stop = AsyncStream<Void> { continuation in
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
    for await _ in stop { break }

    Log.info("Shutting down")
    pump.cancel()
    capture?.stop()
    await group.shutdown()
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
