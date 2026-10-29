// Copyright (c) Sendspin for Mac authors
// Licensed under the Apache License, Version 2.0

#pragma once

#include "ClientCheck.hpp"
#include "LoopbackHandler.hpp"

#include <aspl/Device.hpp>

namespace sendspin {

// Custom device property 'ssau': the audio played to the device, for the macOS Audio for
// Sendspin app. Qualifier: the sample time to read from (CFNumber; negative for "from
// now"). Value: a CFDictionary with "start" (sample time of the first frame), "session"
// (changes when the device's timeline restarts), "rate" (the device's sample rate) and
// "frames" (CFData, float32 interleaved). Only clients that pass ClientCheck get it.
constexpr AudioObjectPropertySelector AudioSelector = 'ssau';

// The Sendspin device: an aspl::Device that also serves 'ssau'.
class SendspinDevice final : public aspl::Device
{
public:
    SendspinDevice(std::shared_ptr<const aspl::Context> context,
        const aspl::DeviceParameters& params,
        std::shared_ptr<LoopbackHandler> loopback,
        CFBundleRef driverBundle);

    std::vector<AudioServerPlugInCustomPropertyInfo> GetCustomProperties() const override;

    Boolean HasProperty(AudioObjectID objectID,
        pid_t clientPID,
        const AudioObjectPropertyAddress* address) const override;

    OSStatus IsPropertySettable(AudioObjectID objectID,
        pid_t clientPID,
        const AudioObjectPropertyAddress* address,
        Boolean* outIsSettable) const override;

    OSStatus GetPropertyDataSize(AudioObjectID objectID,
        pid_t clientPID,
        const AudioObjectPropertyAddress* address,
        UInt32 qualifierDataSize,
        const void* qualifierData,
        UInt32* outDataSize) const override;

    OSStatus GetPropertyData(AudioObjectID objectID,
        pid_t clientPID,
        const AudioObjectPropertyAddress* address,
        UInt32 qualifierDataSize,
        const void* qualifierData,
        UInt32 inDataSize,
        UInt32* outDataSize,
        void* outData) const override;

private:
    const std::shared_ptr<LoopbackHandler> loopback_;
    mutable ClientCheck clientCheck_;
};

} // namespace sendspin
