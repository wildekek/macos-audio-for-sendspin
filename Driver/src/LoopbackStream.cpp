// Copyright (c) macOS Audio for Sendspin authors
// Licensed under the Apache License, Version 2.0

#include "LoopbackStream.hpp"

#include <algorithm>

namespace sendspin {

AudioStreamBasicDescription Float32Format(Float64 sampleRate, UInt32 channelCount)
{
    return AudioStreamBasicDescription{
        .mSampleRate = sampleRate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags =
            kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = UInt32(sizeof(Float32)) * channelCount,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = UInt32(sizeof(Float32)) * channelCount,
        .mChannelsPerFrame = channelCount,
        .mBitsPerChannel = 32,
    };
}

LoopbackStream::LoopbackStream(std::shared_ptr<const aspl::Context> context,
    std::shared_ptr<aspl::Device> device,
    const aspl::StreamParameters& params)
    : Stream(std::move(context), device, params)
    , device_(device)
    , channelCount_(params.Format.mChannelsPerFrame)
{
}

Float64 LoopbackStream::CurrentSampleRate() const
{
    auto device = device_.lock();
    return device ? device->GetNominalSampleRate() : SupportedSampleRates[1];
}

AudioStreamBasicDescription LoopbackStream::GetPhysicalFormat() const
{
    return Float32Format(CurrentSampleRate(), channelCount_);
}

AudioStreamBasicDescription LoopbackStream::GetVirtualFormat() const
{
    return Float32Format(CurrentSampleRate(), channelCount_);
}

std::vector<AudioStreamRangedDescription> LoopbackStream::AvailableFormats() const
{
    std::vector<AudioStreamRangedDescription> formats;
    for (Float64 rate : SupportedSampleRates) {
        AudioStreamRangedDescription format = {};
        format.mFormat = Float32Format(rate, channelCount_);
        format.mSampleRateRange.mMinimum = rate;
        format.mSampleRateRange.mMaximum = rate;
        formats.push_back(format);
    }
    return formats;
}

std::vector<AudioStreamRangedDescription> LoopbackStream::GetAvailablePhysicalFormats() const
{
    return AvailableFormats();
}

std::vector<AudioStreamRangedDescription> LoopbackStream::GetAvailableVirtualFormats() const
{
    return AvailableFormats();
}

OSStatus LoopbackStream::SetPhysicalFormatImpl(const AudioStreamBasicDescription& format)
{
    // Only the sample rate can vary (Check*Format already rejected anything else).
    if (auto device = device_.lock(); device && format.mSampleRate != device->GetNominalSampleRate()) {
        return device->SetNominalSampleRateAsync(format.mSampleRate);
    }
    return kAudioHardwareNoError;
}

OSStatus LoopbackStream::SetVirtualFormatImpl(const AudioStreamBasicDescription& format)
{
    return SetPhysicalFormatImpl(format);
}

} // namespace sendspin
