// Unit test for LoopbackHandler's ring buffer, without coreaudiod.
// Build and run: Driver/tests/run_ring_test.sh

#include "../src/LoopbackHandler.hpp"

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <thread>
#include <vector>

namespace {

constexpr UInt32 Channels = 2;
constexpr int64_t Ring = sendspin::LoopbackHandler::RingFrames;
int failures = 0;

void Expect(bool ok, const char* what)
{
    std::printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) {
        ++failures;
    }
}

std::vector<Float32> Frames(int64_t count, Float32 base)
{
    std::vector<Float32> v(count * Channels);
    for (int64_t i = 0; i < count; ++i) {
        v[i * Channels] = base + i;
        v[i * Channels + 1] = -(base + i);
    }
    return v;
}

void Write(sendspin::LoopbackHandler& h, int64_t at, const std::vector<Float32>& frames)
{
    h.OnWriteMixedOutput(nullptr, 0, Float64(at), frames.data(),
        UInt32(frames.size() * sizeof(Float32)));
}

// `count` frames from `at`, with frames the ring doesn't hold as silence.
std::vector<Float32> Read(sendspin::LoopbackHandler& h, int64_t at, int64_t count)
{
    std::vector<Float32> out(count * Channels, 0.0f);
    const auto frames = h.ReadFrames(at, count);
    const int64_t offset = frames.start - at;
    if (offset >= 0 && offset < count) {
        const auto n = std::min<size_t>(frames.samples.size(), (count - offset) * Channels);
        std::copy_n(frames.samples.begin(), n, out.begin() + offset * Channels);
    }
    return out;
}

bool AllZero(const std::vector<Float32>& v)
{
    for (auto s : v) {
        if (s != 0.0f) {
            return false;
        }
    }
    return true;
}

} // namespace

int main()
{
    sendspin::LoopbackHandler h(Channels);

    Expect(AllZero(Read(h, 0, 512)), "reads silence before anything was written");

    auto a = Frames(512, 1);
    Write(h, 1000, a);
    Expect(Read(h, 1000, 512) == a, "reads back what was written at the same sample time");

    auto partial = Read(h, 1256, 512);
    bool firstHalf = std::equal(a.begin() + 256 * Channels, a.end(), partial.begin());
    bool secondHalfSilent = AllZero({partial.begin() + 256 * Channels, partial.end()});
    Expect(firstHalf && secondHalfSilent, "frames past the write end read as silence");

    // Write far ahead (> one ring later): old audio at the aliased slots must be gone.
    const int64_t later = 1000 + Ring + 4096;
    auto b = Frames(256, 5000);
    Write(h, later, b);
    Expect(AllZero(Read(h, 1000 + Ring, 512)), "gap after a pause is silent, not stale audio");
    Expect(AllZero(Read(h, 1000, 512)), "audio older than one ring is not returned");
    Expect(Read(h, later, 256) == b, "new audio after the gap reads back");

    // Wraparound: a write straddling the end of the ring.
    const int64_t wrapAt = 2 * Ring - 100;
    auto c = Frames(300, 9000);
    Write(h, wrapAt, c);
    Expect(Read(h, wrapAt, 300) == c, "write across the ring boundary reads back intact");

    // A new IO session restarts sample time at zero.
    Expect(h.OnStartIO() == kAudioHardwareNoError, "OnStartIO succeeds");
    Expect(AllZero(Read(h, 0, 512)), "new IO session starts silent");
    auto d = Frames(512, 300);
    Write(h, 512, d);
    Expect(Read(h, 512, 512) == d, "audio reads back after an IO restart");

    // A backwards jump without OnStartIO must not hide new audio either.
    Write(h, 1 << 20, Frames(512, 1));
    auto e = Frames(512, 700);
    Write(h, 2048, e);
    Expect(Read(h, 2048, 512) == e, "audio reads back after the timeline jumps backwards");
    Expect(AllZero(Read(h, 1024, 512)), "frames before the new timeline read as silence");

    // What the app relies on: where a read starts, and the session.
    sendspin::LoopbackHandler r(Channels);
    const uint64_t firstSession = r.ReadFrames(0, 1).session;
    Write(r, 100, Frames(200, 1));
    auto head = r.ReadFrames(-1, 512);
    Expect(head.start == 300 && head.samples.empty(), "a negative start reads from the newest frame on");
    auto capped = r.ReadFrames(100, 50);
    Expect(capped.start == 100 && capped.samples.size() == 50 * Channels, "reads at most maxFrames");
    auto ahead = r.ReadFrames(400, 512);
    Expect(ahead.start == 300 && ahead.samples.empty(), "reading past the write end returns nothing, from the write end");
    Write(r, 300 + 2 * Ring, Frames(100, 7));
    auto lapped = r.ReadFrames(300, 512);
    Expect(lapped.start == 400 + Ring && lapped.samples.size() == 512 * Channels,
        "audio older than one ring is skipped: the start moves up");
    r.OnStartIO();
    auto restarted = r.ReadFrames(-1, 512);
    Expect(restarted.session != firstSession && restarted.start == 0, "a new IO session gets a new session number");

    // A reader beside the realtime writer never gets a torn copy: every frame read is
    // the one written for its sample time.
    sendspin::LoopbackHandler shared(Channels);
    std::atomic<bool> done{false};
    std::thread writer([&] {
        for (int64_t t = 0; t < 40 * Ring; t += 512) {
            std::vector<Float32> block(512 * Channels);
            for (int64_t i = 0; i < 512; ++i) {
                block[i * Channels] = Float32(t + i);
                block[i * Channels + 1] = -Float32(t + i);
            }
            Write(shared, t, block);
        }
        done = true;
    });
    bool consistent = true;
    int64_t framesRead = 0;
    while (!done) {
        const auto frames = shared.ReadFrames(0, 4096);
        for (size_t i = 0; i < frames.samples.size() / Channels; ++i) {
            const Float32 expected = Float32(frames.start + int64_t(i));
            consistent = consistent && frames.samples[i * Channels] == expected
                && frames.samples[i * Channels + 1] == -expected;
        }
        framesRead += int64_t(frames.samples.size() / Channels);
    }
    writer.join();
    Expect(consistent && framesRead > 0, "concurrent reads are never torn");

    std::printf(failures ? "%d FAILED\n" : "all passed\n", failures);
    return failures ? EXIT_FAILURE : EXIT_SUCCESS;
}
