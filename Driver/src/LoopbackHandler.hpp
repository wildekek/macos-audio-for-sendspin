// Copyright (c) Sendspin for Mac authors
// Licensed under the Apache License, Version 2.0

#pragma once

#include <aspl/ControlRequestHandler.hpp>
#include <aspl/IORequestHandler.hpp>

#include <atomic>
#include <cstdint>
#include <vector>

namespace sendspin {

// Loops the device's mixed output back to its input stream.
//
// Audio is kept in a ring buffer indexed by device sample time: output written for
// sample time T is read back by input clients when their input time reaches T. Frames
// that were never written (output idle, or a gap after a pause) read as silence.
//
// Volume and mute controls on the output stream are deliberately *not* applied: the
// capture side forwards them to the Sendspin players instead, so the stream stays
// at full scale.
class LoopbackHandler final : public aspl::ControlRequestHandler,
                              public aspl::IORequestHandler
{
public:
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

    void OnReadClientInput(const std::shared_ptr<aspl::Client>& client,
        const std::shared_ptr<aspl::Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        void* bytes,
        UInt32 bytesCount) override;

private:
    // ~1.4 s at 48 kHz; a power of two so sample time maps to a slot with a mask.
    static constexpr int64_t RingFrames = 1 << 16;

    void ZeroFrames(int64_t from, int64_t to);

    const UInt32 channelCount_;
    std::vector<Float32> ring_;
    // Frames in [validStart_, writeEnd_) — and within one ring of writeEnd_ — hold
    // written audio; everything else reads as silence.
    std::atomic<int64_t> validStart_{0};
    std::atomic<int64_t> writeEnd_{0};
};

} // namespace sendspin
