import Accelerate
import Foundation

/// Finding a known chirp in microphone audio, independent of loudness.
public enum ChirpMatching {
    public static let sampleRate = 48_000

    /// A 50 ms Hann-windowed linear chirp, 800 Hz → 4 kHz: broadband, so its correlation
    /// peak is sharp (sub-millisecond timing) and unlike speech or music.
    public static func chirp(amplitude: Float) -> [Float32] {
        let count = sampleRate / 20
        let (f0, f1) = (800.0, 4_000.0)
        let duration = Double(count) / Double(sampleRate)
        return (0..<count).map { n in
            let t = Double(n) / Double(sampleRate)
            let phase = 2 * Double.pi * (f0 * t + (f1 - f0) / (2 * duration) * t * t)
            let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(n) / Double(count - 1))
            return Float32(Double(amplitude) * window * sin(phase))
        }
    }

    /// Removes rumble and hum below the chirp band (handling noise from something
    /// touching the case would otherwise dominate the correlation's normalization).
    /// Two cascaded second-order high-pass sections at 600 Hz.
    public static func highPassed(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let w0 = 2 * Double.pi * 600 / Double(sampleRate)
        let alpha = sin(w0) / (2 * 0.7071)
        let a0 = 1 + alpha
        let section = [(1 + cos(w0)) / 2 / a0, -(1 + cos(w0)) / a0, (1 + cos(w0)) / 2 / a0,
                       -2 * cos(w0) / a0, (1 - alpha) / a0]
        guard let setup = vDSP_biquad_CreateSetup(section + section, 2) else { return samples }
        defer { vDSP_biquad_DestroySetup(setup) }
        var delay = [Float](repeating: 0, count: 2 * 2 + 2)
        var output = [Float](repeating: 0, count: samples.count)
        vDSP_biquad(setup, &delay, samples, 1, &output, 1, vDSP_Length(samples.count))
        return output
    }

    /// Normalized cross-correlation (0…1 in magnitude) of `template` against `signal`:
    /// element n compares the template with the signal starting at sample n. Callers
    /// high-pass both first.
    public static func normalizedCorrelation(_ signal: [Float], _ template: [Float]) -> [Float] {
        let m = template.count
        guard signal.count >= m, m > 0 else { return [] }
        let outputCount = signal.count - m + 1
        var correlation = [Float](repeating: 0, count: outputCount)
        // vDSP_conv with a positive filter stride correlates.
        vDSP_conv(signal, 1, template, 1, &correlation, 1, vDSP_Length(outputCount), vDSP_Length(m))
        var templateEnergy: Float = 0
        vDSP_svesq(template, 1, &templateEnergy, vDSP_Length(m))
        var runningSum = [Double](repeating: 0, count: signal.count + 1)
        for (i, sample) in signal.enumerated() { runningSum[i + 1] = runningSum[i] + Double(sample * sample) }
        return (0..<outputCount).map { n in
            let energy = Float(runningSum[n + m] - runningSum[n])
            return energy > 1e-12 ? abs(correlation[n]) / sqrt(templateEnergy * energy) : 0
        }
    }

    /// The most chirp-like position in `samples` (raw microphone audio).
    public static func bestMatch(of chirp: [Float32], in samples: [Float]) -> (offset: Int, similarity: Float)? {
        let similarity = normalizedCorrelation(highPassed(samples), highPassed(chirp))
        guard let peak = similarity.indices.max(by: { similarity[$0] < similarity[$1] }) else { return nil }
        return (peak, similarity[peak])
    }
}
