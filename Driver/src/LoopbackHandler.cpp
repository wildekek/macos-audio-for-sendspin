// Copyright (c) macOS Audio for Sendspin authors
// Licensed under the Apache License, Version 2.0

#include "LoopbackHandler.hpp"

#include <algorithm>
#include <cstring>

namespace sendspin {

LoopbackHandler::LoopbackHandler(UInt32 channelCount)
    : channelCount_(channelCount)
    , ring_(static_cast<size_t>(RingFrames) * channelCount, 0.0f)
{
}

OSStatus LoopbackHandler::OnStartIO()
{
    // Runs on the control thread before the first IO cycle of a session.
    validStart_.store(0, std::memory_order_relaxed);
    writeEnd_.store(0, std::memory_order_release);
    return kAudioHardwareNoError;
}

void LoopbackHandler::OnProcessMixedOutput(const std::shared_ptr<aspl::Stream>&,
    Float64,
    Float64,
    Float32*,
    UInt32,
    UInt32)
{
    // Intentionally empty: don't apply the stream's volume/mute (see header).
}

void LoopbackHandler::ZeroFrames(int64_t from, int64_t to)
{
    // Never more than one full ring is meaningful.
    from = std::max(from, to - RingFrames);
    for (int64_t t = from; t < to; ++t) {
        Float32* slot = &ring_[static_cast<size_t>(t & (RingFrames - 1)) * channelCount_];
        std::memset(slot, 0, channelCount_ * sizeof(Float32));
    }
}

void LoopbackHandler::OnWriteMixedOutput(const std::shared_ptr<aspl::Stream>&,
    Float64,
    Float64 timestamp,
    const void* bytes,
    UInt32 bytesCount)
{
    const auto* samples = static_cast<const Float32*>(bytes);
    const int64_t frames = bytesCount / (sizeof(Float32) * channelCount_);
    const int64_t start = static_cast<int64_t>(timestamp);

    int64_t previousEnd = writeEnd_.load(std::memory_order_relaxed);
    if (start < validStart_.load(std::memory_order_relaxed) || start + frames < previousEnd - RingFrames) {
        // The timeline jumped backwards: start a new one at this write.
        validStart_.store(start, std::memory_order_relaxed);
        previousEnd = start;
    } else if (start > previousEnd) {
        // Silence any gap since the last write, so stale audio from a previous
        // lap of the ring is never played back.
        ZeroFrames(previousEnd, start);
    }

    for (int64_t i = 0; i < frames; ++i) {
        const int64_t t = start + i;
        Float32* slot = &ring_[static_cast<size_t>(t & (RingFrames - 1)) * channelCount_];
        std::memcpy(slot, samples + i * channelCount_, channelCount_ * sizeof(Float32));
    }

    writeEnd_.store(std::max(previousEnd, start + frames), std::memory_order_release);
}

void LoopbackHandler::OnReadClientInput(const std::shared_ptr<aspl::Client>&,
    const std::shared_ptr<aspl::Stream>&,
    Float64,
    Float64 timestamp,
    void* bytes,
    UInt32 bytesCount)
{
    auto* samples = static_cast<Float32*>(bytes);
    const int64_t frames = bytesCount / (sizeof(Float32) * channelCount_);
    const int64_t start = static_cast<int64_t>(timestamp);
    const int64_t writeEnd = writeEnd_.load(std::memory_order_acquire);
    const int64_t oldestValid =
        std::max(validStart_.load(std::memory_order_relaxed), writeEnd - RingFrames);

    for (int64_t i = 0; i < frames; ++i) {
        const int64_t t = start + i;
        Float32* out = samples + i * channelCount_;
        if (t >= writeEnd || t < oldestValid) {
            std::memset(out, 0, channelCount_ * sizeof(Float32));
        } else {
            const Float32* slot =
                &ring_[static_cast<size_t>(t & (RingFrames - 1)) * channelCount_];
            std::memcpy(out, slot, channelCount_ * sizeof(Float32));
        }
    }
}

} // namespace sendspin
