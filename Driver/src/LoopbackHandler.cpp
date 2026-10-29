// Copyright (c) Sendspin for Mac authors
// Licensed under the Apache License, Version 2.0

#include "LoopbackHandler.hpp"

#include <algorithm>
#include <cstring>
#include <thread>

namespace sendspin {

LoopbackHandler::LoopbackHandler(UInt32 channelCount)
    : channelCount_(channelCount)
    , ring_(static_cast<size_t>(RingFrames) * channelCount, 0.0f)
{
}

OSStatus LoopbackHandler::OnStartIO()
{
    // Runs on the control thread before the first IO cycle of a session.
    writeSeq_.fetch_add(1, std::memory_order_relaxed);
    std::atomic_thread_fence(std::memory_order_release);
    validStart_.store(0, std::memory_order_relaxed);
    writeEnd_.store(0, std::memory_order_relaxed);
    session_.fetch_add(1, std::memory_order_relaxed);
    writeSeq_.fetch_add(1, std::memory_order_release);
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

    writeSeq_.fetch_add(1, std::memory_order_relaxed);
    std::atomic_thread_fence(std::memory_order_release);

    int64_t previousEnd = writeEnd_.load(std::memory_order_relaxed);
    if (start < validStart_.load(std::memory_order_relaxed) || start + frames < previousEnd - RingFrames) {
        // The timeline jumped backwards: start a new one at this write. For readers it's a
        // new session, as after OnStartIO: their sample times no longer relate.
        validStart_.store(start, std::memory_order_relaxed);
        session_.fetch_add(1, std::memory_order_relaxed);
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

    writeEnd_.store(std::max(previousEnd, start + frames), std::memory_order_relaxed);
    writeSeq_.fetch_add(1, std::memory_order_release);
}

LoopbackHandler::Frames LoopbackHandler::ReadFrames(int64_t from, int64_t maxFrames) const
{
    // A write lasts microseconds, and comes once per IO cycle: a few tries always do.
    for (int attempt = 0; attempt < 100; ++attempt) {
        const uint64_t seq = writeSeq_.load(std::memory_order_acquire);
        if (seq & 1) {
            std::this_thread::yield();
            continue;
        }
        const int64_t writeEnd = writeEnd_.load(std::memory_order_relaxed);
        const int64_t oldestValid =
            std::max(validStart_.load(std::memory_order_relaxed), writeEnd - RingFrames);

        Frames result;
        result.session = session_.load(std::memory_order_relaxed);
        result.start = from < 0 ? writeEnd : std::clamp(from, oldestValid, writeEnd);
        const int64_t end = std::min(writeEnd, result.start + std::min(maxFrames, RingFrames));
        const int64_t count = std::max<int64_t>(0, end - result.start);
        result.samples.resize(static_cast<size_t>(count) * channelCount_);
        for (int64_t i = 0; i < count; ++i) {
            const int64_t t = result.start + i;
            const Float32* slot = &ring_[static_cast<size_t>(t & (RingFrames - 1)) * channelCount_];
            std::memcpy(&result.samples[static_cast<size_t>(i) * channelCount_], slot,
                channelCount_ * sizeof(Float32));
        }

        // The copy is only good if no write started meanwhile.
        std::atomic_thread_fence(std::memory_order_acquire);
        if (writeSeq_.load(std::memory_order_relaxed) == seq) {
            return result;
        }
    }
    // Nothing this time; the app reads again shortly.
    return Frames{std::max<int64_t>(from, 0), session_.load(std::memory_order_relaxed), {}};
}

} // namespace sendspin
