import Accelerate
import Foundation

/// A visualizer stream's configuration: what a client asks for in client/state, and what we
/// echo in stream/start (roles/visualizer/v1.md).
public struct VisualizerConfig: Codable, Sendable, Equatable {
    public struct Spectrum: Codable, Sendable, Equatable {
        public var nDispBins: Int
        /// 'mel', 'log' or 'lin'.
        public var scale: String
        public var fMin: Int
        public var fMax: Int

        enum CodingKeys: String, CodingKey {
            case scale
            case nDispBins = "n_disp_bins"
            case fMin = "f_min"
            case fMax = "f_max"
        }
    }

    /// 'beat', 'loudness', 'f_peak', 'peak', 'spectrum'.
    public var types: [String]
    /// Periodic frames per second per type.
    public var rateMax: Int
    public var spectrum: Spectrum?

    enum CodingKeys: String, CodingKey {
        case types, spectrum
        case rateMax = "rate_max"
    }

    /// The types we compute live. `beat` needs offline beat tracking, which we don't have:
    /// unsupported types are silently left out of stream/start.
    static let computedTypes = ["loudness", "f_peak", "spectrum", "peak"]
    static let maxRate = 120
    /// Keeps a frame's size sensible, at about the FFT's own bin count.
    static let maxDisplayBins = 1024

    /// What we'll stream for this request: a subset of its types, at most its rate, and its
    /// spectrum configuration unchanged (or no spectrum).
    func negotiated() -> VisualizerConfig {
        var types: [String] = []
        for type in self.types where Self.computedTypes.contains(type) && !types.contains(type) {
            types.append(type)
        }
        if let spectrum, !Self.isUsable(spectrum) { types.removeAll { $0 == "spectrum" } }
        return VisualizerConfig(types: types, rateMax: max(1, min(rateMax, Self.maxRate)),
                                spectrum: types.contains("spectrum") ? spectrum : nil)
    }

    private static func isUsable(_ spectrum: Spectrum) -> Bool {
        (1...maxDisplayBins).contains(spectrum.nDispBins) && ["mel", "log", "lin"].contains(spectrum.scale)
            && spectrum.fMin >= 0 && spectrum.fMax > spectrum.fMin
    }

    /// A request for a spectrum without its configuration: a protocol error.
    var isMalformed: Bool { types.contains("spectrum") && spectrum == nil }
}

/// Computes a visualizer stream's frames from the group's audio, each a binary message
/// `[type][timestamp][data]` timed to when its audio plays (roles/visualizer/v1.md,
/// Visualization Data). The measures follow aiosendspin's, so displays look the same with
/// either server: a 2048-sample Hann-windowed FFT at 48 kHz (about 43 ms), A-weighted,
/// scaled −60 dB → 0 to 0 dB → 65535 against a full-scale sine.
struct VisualizerAnalyzer {
    static let loudnessType: UInt8 = 16
    static let fPeakType: UInt8 = 18
    static let spectrumType: UInt8 = 19
    static let peakType: UInt8 = 20

    let config: VisualizerConfig
    let sampleRate: Int
    let channels: Int

    private let window: Int
    private let hann: [Float]
    private let fft: vDSP.FFT<DSPSplitComplex>
    /// Linear A-weighting gain per FFT bin.
    private let aWeight: [Float]
    /// The display bin of each FFT bin, or -1 outside f_min ..< f_max.
    private let displayBin: [Int]
    private let hopUs: Int64
    private let periodic: Bool
    private let onsets: Bool

    /// Mono samples, the oldest at `bufferStart` (a running sample count) on the timeline
    /// that starts at `anchorUs`.
    private var buffer: [Float] = []
    private var bufferStart: Int64 = 0
    private var anchorUs: Int64?
    private var nextPeriodicUs: Int64 = .min
    private var nextOnsetUs: Int64 = .min
    /// The last frame's timestamp: frames never go back in time (Visualizer messages).
    private(set) var lastUs: Int64?

    private var loudnessAverage: Float?
    private var spectrumAverage: [Float]?
    private var fPeakBin: Int?
    private var energyAverage: Float?
    private var lastOnsetUs: Int64?

    /// Onsets are events, not periodic frames: looked for every 10 ms whatever the rate.
    static let onsetHopUs: Int64 = 10_000
    /// Input that strays further from the running timeline is a new start, after a gap; less
    /// is the capture clock drifting, which the timeline follows.
    static let resyncThresholdUs: Int64 = 100_000

    /// A new analysis whose frames come after `lastUs`, as a stream that changes its
    /// configuration or sample rate must.
    init(config: VisualizerConfig, sampleRate: Int, channels: Int, after lastUs: Int64? = nil) {
        self.config = config
        self.sampleRate = sampleRate
        self.channels = channels
        self.lastUs = lastUs
        var window = 256
        while window < 2048 * sampleRate / 48_000 { window <<= 1 }
        self.window = window
        hann = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: window, isHalfWindow: false)
        fft = vDSP.FFT(log2n: vDSP_Length(window.trailingZeroBitCount), radix: .radix2, ofType: DSPSplitComplex.self)!
        let bins = window / 2 + 1
        let binHz = Double(sampleRate) / Double(window)
        aWeight = (0..<bins).map { Float(Self.aWeighting(max(Double($0) * binHz, 1))) }
        if let spectrum = config.spectrum {
            let edges = Self.binEdges(spectrum)
            displayBin = (0..<bins).map { bin in
                let hz = Double(bin) * binHz
                guard hz >= edges.first!, hz < edges.last! else { return -1 }
                return min(edges.lastIndex { $0 <= hz }!, spectrum.nDispBins - 1)
            }
        } else {
            displayBin = []
        }
        hopUs = (1_000_000 + Int64(config.rateMax) - 1) / Int64(config.rateMax)
        periodic = config.types.contains { $0 != "peak" }
        onsets = config.types.contains("peak")
    }

    /// The frames for one block of the group's audio, timestamp first, in time order.
    mutating func process(_ pcm: PCMBuffer, timestampUs: Int64) -> [(timestampUs: Int64, message: Data)] {
        guard periodic || onsets, pcm.channels == channels, pcm.frameCount > 0 else { return [] }
        let rate = Int64(sampleRate)
        let end = bufferStart + Int64(buffer.count)
        if let anchorUs, abs(anchorUs + end * 1_000_000 / rate - timestampUs) <= Self.resyncThresholdUs {
            // Contiguous: windows line up with the block's own timestamp.
            self.anchorUs = timestampUs - end * 1_000_000 / rate
        } else {
            // The first block, or one after a gap: start over at its timestamp.
            buffer.removeAll()
            bufferStart = 0
            anchorUs = timestampUs
            let firstUs = max(timestampUs + Int64(window) * 1_000_000 / rate, lastUs ?? .min)
            nextPeriodicUs = max(firstUs, lastUs.map { $0 + hopUs } ?? .min)
            nextOnsetUs = firstUs
            loudnessAverage = nil
            spectrumAverage = nil
            fPeakBin = nil
            energyAverage = nil
        }
        appendMono(pcm)

        var frames: [(Int64, Data)] = []
        let endUs = anchorUs! + (bufferStart + Int64(buffer.count)) * 1_000_000 / rate
        while true {
            let us = min(periodic ? nextPeriodicUs : .max, onsets ? nextOnsetUs : .max)
            guard us <= endUs else { break }
            let endIndex = Int((us - anchorUs!) * rate / 1_000_000 - bufferStart)
            if endIndex >= window, endIndex <= buffer.count {
                let magnitudes = weightedMagnitudes(buffer[(endIndex - window)..<endIndex])
                if periodic, us == nextPeriodicUs { frames += periodicFrames(magnitudes, at: us) }
                if onsets, us == nextOnsetUs, let strength = onset(magnitudes, at: us) {
                    frames.append((us, Self.message(Self.peakType, us, [strength])))
                }
                lastUs = us
            }
            if periodic, us == nextPeriodicUs { nextPeriodicUs += hopUs }
            if onsets, us == nextOnsetUs { nextOnsetUs += Self.onsetHopUs }
        }
        if buffer.count > 2 * window {
            let drop = buffer.count - window
            buffer.removeFirst(drop)
            bufferStart += Int64(drop)
        }
        return frames
    }

    private mutating func appendMono(_ pcm: PCMBuffer) {
        guard channels > 1 else {
            buffer += pcm.samples
            return
        }
        let scale = 1 / Float(channels)
        buffer.reserveCapacity(buffer.count + pcm.frameCount)
        for frame in 0..<pcm.frameCount {
            var sum: Float = 0
            for channel in 0..<channels { sum += pcm.samples[frame * channels + channel] }
            buffer.append(sum * scale)
        }
    }

    /// Magnitude per FFT bin, DC dropped, A-weighted; a full-scale sine peaks at window/4.
    private func weightedMagnitudes(_ samples: ArraySlice<Float>) -> [Float] {
        let windowed = vDSP.multiply(samples, hann)
        let half = window / 2
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half + 1)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBufferPointer {
                    $0.withMemoryRebound(to: DSPComplex.self) { vDSP_ctoz($0.baseAddress!, 2, &split, 1, vDSP_Length(half)) }
                }
                fft.forward(input: split, output: &split)
                // vDSP's real FFT comes out doubled; DC and Nyquist share the first element.
                for bin in 1..<half {
                    magnitudes[bin] = 0.5 * (split.realp[bin] * split.realp[bin] + split.imagp[bin] * split.imagp[bin]).squareRoot()
                }
                magnitudes[half] = 0.5 * abs(split.imagp[0])
            }
        }
        return vDSP.multiply(magnitudes, aWeight)
    }

    private mutating func periodicFrames(_ magnitudes: [Float], at us: Int64) -> [(Int64, Data)] {
        var frames: [(Int64, Data)] = []
        let fullScale = Float(window) / 4
        for type in config.types {
            switch type {
            case "loudness":
                // RMS from the spectrum; a full-scale sine through the window has sqrt(3/16).
                let power = vDSP.sum(vDSP.square(magnitudes))
                let rms = (2 * power).squareRoot() / Float(window)
                let level = Self.decibelScale(rms / (3.0 / 16.0).squareRoot())
                let average = loudnessAverage.map { 0.5 * level + 0.5 * $0 } ?? level
                loudnessAverage = average
                frames.append((us, Self.message(Self.loudnessType, us, Self.level(average))))
            case "f_peak":
                let (hz, amplitude) = fPeak(magnitudes, fullScale: fullScale)
                frames.append((us, Self.message(Self.fPeakType, us, Self.uint16(hz) + Self.level(amplitude))))
            case "spectrum":
                guard let spectrum = config.spectrum else { continue }
                var power = [Float](repeating: 0, count: spectrum.nDispBins)
                for (bin, display) in displayBin.enumerated() where display >= 0 {
                    power[display] += magnitudes[bin] * magnitudes[bin]
                }
                let levels = power.map { Self.decibelScale($0.squareRoot() / fullScale) }
                let average = spectrumAverage.map { zip(levels, $0).map { 0.4 * $0 + 0.6 * $1 } } ?? levels
                spectrumAverage = average
                frames.append((us, Self.message(Self.spectrumType, us, average.flatMap(Self.level))))
            default:
                continue
            }
        }
        return frames
    }

    /// The dominant bin, held unless another beats it by 10 %, refined between its neighbours.
    private mutating func fPeak(_ magnitudes: [Float], fullScale: Float) -> (hz: Int, amplitude: Float) {
        guard let candidate = magnitudes.indices.max(by: { magnitudes[$0] < magnitudes[$1] }) else { return (0, 0) }
        var bin = candidate
        if let held = fPeakBin, held != candidate, magnitudes[candidate] < 1.1 * magnitudes[held] { bin = held }
        fPeakBin = bin
        guard magnitudes[bin] > 0 else { return (0, 0) }
        var peak = magnitudes[bin]
        var position = Float(bin)
        if bin > 0, bin < magnitudes.count - 1 {
            let (a, b, c) = (magnitudes[bin - 1], magnitudes[bin], magnitudes[bin + 1])
            let denominator = a - 2 * b + c
            if abs(denominator) > 1e-12 {
                let delta = max(-1, min(1, 0.5 * (a - c) / denominator))
                position += delta
                peak = b - 0.25 * (a - c) * delta
            }
        }
        let hz = Int((position * Float(sampleRate) / Float(window)).rounded())
        guard hz >= 1 else { return (0, 0) }
        return (min(hz, 65535), Self.decibelScale(peak / fullScale))
    }

    /// An energy onset: this window's energy well above its running average, at least 80 ms
    /// after the last one (from aiosendspin, but looked for more often, so the average catches
    /// up with an onset's rise while it's held off). Strength scales the excess over about 6x into 1-255.
    private mutating func onset(_ magnitudes: [Float], at us: Int64) -> UInt8? {
        let energy = vDSP.sum(vDSP.square(magnitudes))
        guard let average = energyAverage, average > 0 else {
            energyAverage = max(energy, 1e-12)
            return nil
        }
        if let lastOnsetUs, us - lastOnsetUs < 80_000 {
            // The window is still filling with the onset's sound: its rise is the same onset.
            energyAverage = max(energy, 0.9 * average + 0.1 * energy)
            return nil
        }
        guard energy > 1.6 * average else {
            energyAverage = 0.9 * average + 0.1 * energy
            return nil
        }
        energyAverage = 0.6 * average + 0.4 * energy
        lastOnsetUs = us
        let excess = energy / average - 1.6
        return UInt8(max(1, min(1, excess / 6) * 255))
    }

    /// −60 dB → 0, 0 dB → 1, linear in dB.
    private static func decibelScale(_ ratio: Float) -> Float {
        max(0, min(1, (20 * log10(max(ratio, 1e-10)) + 60) / 60))
    }

    /// 0 ... 1 as the spec's uint16 level.
    private static func level(_ value: Float) -> [UInt8] {
        uint16(Int(max(0, min(1, value)) * 65535))
    }

    private static func uint16(_ value: Int) -> [UInt8] {
        let integer = UInt16(clamping: value)
        return [UInt8(integer >> 8), UInt8(integer & 0xFF)]
    }

    private static func message(_ type: UInt8, _ us: Int64, _ data: [UInt8]) -> Data {
        var message = Data([type])
        withUnsafeBytes(of: us.bigEndian) { message.append(contentsOf: $0) }
        message.append(contentsOf: data)
        return message
    }

    /// The IEC 61672 A-weighting curve as a linear gain, within −50 ... +6 dB.
    private static func aWeighting(_ hz: Double) -> Double {
        let f2 = hz * hz
        let numerator = pow(12194.0, 2) * f2 * f2
        let denominator = (f2 + pow(20.6, 2)) * ((f2 + pow(107.7, 2)) * (f2 + pow(737.9, 2))).squareRoot()
            * (f2 + pow(12194.0, 2))
        let db = 2 + 20 * log10(max(numerator / max(denominator, 1e-20), 1e-12))
        return pow(10, max(-50, min(6, db)) / 20)
    }

    /// The display bins' edges in Hz, n + 1 of them, spaced by the spectrum's scale.
    private static func binEdges(_ spectrum: VisualizerConfig.Spectrum) -> [Double] {
        let n = spectrum.nDispBins
        let low = Double(spectrum.fMin), high = Double(spectrum.fMax)
        func spaced(_ a: Double, _ b: Double) -> [Double] { (0...n).map { a + (b - a) * Double($0) / Double(n) } }
        switch spectrum.scale {
        case "log":
            return spaced(log10(max(low, 1)), log10(high)).map { pow(10, $0) }
        case "mel":
            func mel(_ hz: Double) -> Double { 2595 * log10(1 + hz / 700) }
            return spaced(mel(low), mel(high)).map { 700 * (pow(10, $0 / 2595) - 1) }
        default:
            return spaced(low, high)
        }
    }
}

/// The visualizer frames a client may still hold (visualizer@v1 support, `buffer_capacity`):
/// those with future timestamps, until stream/clear or stream/end.
struct VisualizerBufferAccount {
    private var frames: [(timestampUs: Int64, bytes: Int)] = []

    mutating func admit(bytes: Int, timestampUs: Int64, nowUs: Int64, capacity: Int) -> Bool {
        frames.removeAll { $0.timestampUs <= nowUs }
        guard frames.reduce(0, { $0 + $1.bytes }) + bytes <= capacity else { return false }
        frames.append((timestampUs, bytes))
        return true
    }
}
