// Copyright (c) Sendspin for Mac authors
// Licensed under the Apache License, Version 2.0

#pragma once

#include <aspl/Device.hpp>
#include <aspl/Stream.hpp>

#include <array>

namespace sendspin {

// Sample rates the device offers; the app switches between them.
constexpr std::array<Float64, 6> SupportedSampleRates = {
    44100, 48000, 88200, 96000, 176400, 192000};

// 32-bit float interleaved: carries 16- and 24-bit sources losslessly, and it's what
// the HAL mixes in, so no format conversion happens on the way into the loopback.
AudioStreamBasicDescription Float32Format(Float64 sampleRate, UInt32 channelCount);

// A stream whose format always follows the device's nominal sample rate, so the
// device and its streams can't disagree after a rate change. A client changing the
// stream's format (as Audio MIDI Setup does) changes the device's rate instead.
class LoopbackStream final : public aspl::Stream
{
public:
    LoopbackStream(std::shared_ptr<const aspl::Context> context,
        std::shared_ptr<aspl::Device> device,
        const aspl::StreamParameters& params);

    AudioStreamBasicDescription GetPhysicalFormat() const override;
    AudioStreamBasicDescription GetVirtualFormat() const override;
    std::vector<AudioStreamRangedDescription> GetAvailablePhysicalFormats() const override;
    std::vector<AudioStreamRangedDescription> GetAvailableVirtualFormats() const override;

protected:
    OSStatus SetPhysicalFormatImpl(const AudioStreamBasicDescription& format) override;
    OSStatus SetVirtualFormatImpl(const AudioStreamBasicDescription& format) override;

private:
    Float64 CurrentSampleRate() const;
    std::vector<AudioStreamRangedDescription> AvailableFormats() const;

    const std::weak_ptr<aspl::Device> device_;
    const UInt32 channelCount_;
};

} // namespace sendspin
