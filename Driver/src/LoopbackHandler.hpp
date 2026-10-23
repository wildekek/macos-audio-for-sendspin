// Copyright (c) macOS Audio for Sendspin authors
// Licensed under the Apache License, Version 2.0

#pragma once

#include <aspl/ControlRequestHandler.hpp>
#include <aspl/IORequestHandler.hpp>

#include <atomic>
#include <cstdint>
#include <vector>

namespace sendspin {

// Keeps the device's mixed output for the macOS Audio for Sendspin app to read.
//
// Audio is kept in a ring buffer indexed by device sample time: output written for
// sample time T is what the app reads for T. Frames that were never written (output
// idle, or a gap after a pause) read as silence.
//
// The app reads through a device property (see SendspinDevice), not an input stream:
// capturing an input needs microphone permission, and this is a speaker.
//
// Volume and mute controls on the output stream are deliberately *not* applied: the
// app forwards them to the Sendspin players instead, so the stream stays at full scale.
class LoopbackHandler final : public aspl::ControlRequestHandler,
                              public aspl::IORequestHandler
{
public:
    // ~1.4 s at 192 kHz; a power of two so sample time maps to a slot with a mask.
    static constexpr int64_t RingFrames = 1 << 18;

    explicit LoopbackHandler(UInt32 channelCount);

    // The device's sample time restarts at zero whenever IO starts, so the
    // timeline of the previous IO session must be forgotten.
    OSStatus OnStartIO() override;

    void OnProcessMixedOutput(const std::shared_ptr<aspl::Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        Float32* frames,
        UInt32 frameCount,
        UInt32 channelCount) override;

    void OnWriteMixedOutput(const std::shared_ptr<aspl::Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        const void* bytes,
        UInt32 bytesCount) override;

    struct Frames {
        // Sample time of the first frame: the requested one, or the oldest (newest) frame
        // held when that's before (after) what the ring holds.
        int64_t start = 0;
        // Goes up with every IO session; sample times of different sessions don't relate.
        uint64_t session = 0;
        std::vector<Float32> samples; // interleaved
    };

    // Written audio from sample time `from` on (from the newest frame when `from` is
    // negative), at most `maxFrames`. Runs off the realtime thread, beside the writer.
    Frames ReadFrames(int64_t from, int64_t maxFrames) const;

private:
    void ZeroFrames(int64_t from, int64_t to);

    const UInt32 channelCount_;
    std::vector<Float32> ring_;
    // Frames in [validStart_, writeEnd_) — and within one ring of writeEnd_ — hold
    // written audio; everything else reads as silence.
    std::atomic<int64_t> validStart_{0};
    std::atomic<int64_t> writeEnd_{0};
    std::atomic<uint64_t> session_{0};
    // Odd while the ring is being changed, so a reader can tell its copy is torn and
    // try again; the realtime writer never waits.
    std::atomic<uint64_t> writeSeq_{0};
};

} // namespace sendspin
