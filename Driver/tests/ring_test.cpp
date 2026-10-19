// Unit test for LoopbackHandler's ring buffer, without coreaudiod.
// Build and run: Driver/tests/run_ring_test.sh

#include "../src/LoopbackHandler.hpp"

#include <cstdio>
#include <cstdlib>
#include <vector>

namespace {

constexpr UInt32 Channels = 2;
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

std::vector<Float32> Read(sendspin::LoopbackHandler& h, int64_t at, int64_t count)
{
    std::vector<Float32> out(count * Channels, 12345.0f);
    h.OnReadClientInput(nullptr, nullptr, 0, Float64(at), out.data(),
        UInt32(out.size() * sizeof(Float32)));
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
    const int64_t later = 1000 + (1 << 16) + 4096;
    auto b = Frames(256, 5000);
    Write(h, later, b);
    Expect(AllZero(Read(h, 1000 + (1 << 16), 512)), "gap after a pause is silent, not stale audio");
    Expect(AllZero(Read(h, 1000, 512)), "audio older than one ring is not returned");
    Expect(Read(h, later, 256) == b, "new audio after the gap reads back");

    // Wraparound: a write straddling the end of the ring.
    const int64_t wrapAt = (int64_t(1) << 17) - 100;
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

    std::printf(failures ? "%d FAILED\n" : "all passed\n", failures);
    return failures ? EXIT_FAILURE : EXIT_SUCCESS;
}
