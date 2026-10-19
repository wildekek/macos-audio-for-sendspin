# /// script
# requires-python = ">=3.12"
# dependencies = ["numpy>=2.5.4", "sounddevice>=0.5.6"]
# ///
"""Verify the Sendspin device loops its output back to its input, unaltered.

Plays a test signal into the device's output while recording its input, then checks:
- the recorded audio is the played audio, sample-exact, after a fixed delay;
- the loopback delay;
- frames after playback stops read as silence (no stale ring-buffer audio).

Run:  uv run Driver/tests/loopback_check.py [low|high]
"""

import sys

import numpy as np
import sounddevice as sd

DEVICE = "Sendspin"
# Measure at the device's current sample rate, so nothing gets resampled on the way.
RATE = int(sd.query_devices(DEVICE, "input")["default_samplerate"])
LATENCY = sys.argv[1] if len(sys.argv) > 1 else "high"  # PortAudio buffering: "low" or "high"


def main() -> int:
    rng = np.random.default_rng(1)
    signal_s, tail_s = 2.0, 0.75
    n = int(RATE * signal_s)
    # Noise is unambiguous to cross-correlate; keep it at a moderate level.
    played = np.zeros((n + int(RATE * tail_s), 2), dtype=np.float32)
    played[:n] = (rng.uniform(-0.25, 0.25, size=(n, 2))).astype(np.float32)

    recorded = sd.playrec(played, samplerate=RATE, channels=2, dtype="float32",
                          device=(DEVICE, DEVICE), latency=LATENCY, blocking=True)

    # Locate the signal in the recording by cross-correlating channel 0.
    ref = played[: RATE // 2, 0]
    corr = np.correlate(recorded[:, 0], ref, mode="valid")
    delay = int(np.argmax(np.abs(corr)))
    print(f"device rate: {RATE} Hz")
    print(f"loopback delay: {delay} frames ({delay / RATE * 1000:.1f} ms)")

    usable = min(n, len(recorded) - delay)
    got = recorded[delay: delay + usable]
    want = played[:usable]
    max_err = float(np.max(np.abs(got - want)))
    gain = float(np.sqrt(np.mean(got**2)) / np.sqrt(np.mean(want**2)))
    print(f"compared {usable} frames: max abs error {max_err:.2e}, gain {gain:.6f}")

    tail = recorded[delay + n + RATE // 10:]  # skip 100 ms after the signal ends
    tail_peak = float(np.max(np.abs(tail))) if len(tail) else 0.0
    print(f"after playback: {len(tail)} frames, peak {tail_peak:.2e}")

    ok = usable > RATE and max_err < 1e-6 and tail_peak == 0.0
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
