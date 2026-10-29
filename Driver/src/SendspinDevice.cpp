// Copyright (c) Sendspin for Mac authors
// Licensed under the Apache License, Version 2.0

#include "SendspinDevice.hpp"

namespace sendspin {

namespace {

// Per read; the app reads every few milliseconds, so this only matters when catching up.
constexpr int64_t MaxReadFrames = 1 << 15;

CFNumberRef Number(int64_t value)
{
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &value);
}

} // namespace

SendspinDevice::SendspinDevice(std::shared_ptr<const aspl::Context> context,
    const aspl::DeviceParameters& params,
    std::shared_ptr<LoopbackHandler> loopback,
    CFBundleRef driverBundle)
    : Device(std::move(context), params)
    , loopback_(std::move(loopback))
    , clientCheck_(driverBundle)
{
}

std::vector<AudioServerPlugInCustomPropertyInfo> SendspinDevice::GetCustomProperties() const
{
    auto properties = Device::GetCustomProperties();
    properties.push_back({AudioSelector,
        kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
        kAudioServerPlugInCustomPropertyDataTypeCFPropertyList});
    return properties;
}

Boolean SendspinDevice::HasProperty(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address) const
{
    return address->mSelector == AudioSelector || Device::HasProperty(objectID, clientPID, address);
}

OSStatus SendspinDevice::IsPropertySettable(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address,
    Boolean* outIsSettable) const
{
    if (address->mSelector != AudioSelector) {
        return Device::IsPropertySettable(objectID, clientPID, address, outIsSettable);
    }
    *outIsSettable = false;
    return kAudioHardwareNoError;
}

OSStatus SendspinDevice::GetPropertyDataSize(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address,
    UInt32 qualifierDataSize,
    const void* qualifierData,
    UInt32* outDataSize) const
{
    if (address->mSelector != AudioSelector) {
        return Device::GetPropertyDataSize(
            objectID, clientPID, address, qualifierDataSize, qualifierData, outDataSize);
    }
    *outDataSize = sizeof(CFPropertyListRef);
    return kAudioHardwareNoError;
}

OSStatus SendspinDevice::GetPropertyData(AudioObjectID objectID,
    pid_t clientPID,
    const AudioObjectPropertyAddress* address,
    UInt32 qualifierDataSize,
    const void* qualifierData,
    UInt32 inDataSize,
    UInt32* outDataSize,
    void* outData) const
{
    if (address->mSelector != AudioSelector) {
        return Device::GetPropertyData(objectID, clientPID, address, qualifierDataSize,
            qualifierData, inDataSize, outDataSize, outData);
    }
    if (inDataSize < sizeof(CFPropertyListRef)) {
        return kAudioHardwareBadPropertySizeError;
    }
    if (!clientCheck_.Allows(clientPID)) {
        return kAudioHardwareIllegalOperationError;
    }

    int64_t from = -1;
    if (qualifierData && qualifierDataSize == sizeof(CFPropertyListRef)) {
        auto qualifier = *static_cast<const CFPropertyListRef*>(qualifierData);
        if (qualifier && CFGetTypeID(qualifier) == CFNumberGetTypeID()) {
            CFNumberGetValue(CFNumberRef(qualifier), kCFNumberSInt64Type, &from);
        }
    }
    const auto frames = loopback_->ReadFrames(from, MaxReadFrames);

    CFNumberRef start = Number(frames.start);
    CFNumberRef session = Number(int64_t(frames.session));
    CFNumberRef rate = Number(int64_t(GetNominalSampleRate()));
    CFDataRef samples = CFDataCreate(kCFAllocatorDefault,
        reinterpret_cast<const UInt8*>(frames.samples.data()),
        CFIndex(frames.samples.size() * sizeof(Float32)));
    const void* keys[] = {CFSTR("start"), CFSTR("session"), CFSTR("rate"), CFSTR("frames")};
    const void* values[] = {start, session, rate, samples};
    CFDictionaryRef value = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 4,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(start);
    CFRelease(session);
    CFRelease(rate);
    CFRelease(samples);

    // The HAL releases it.
    *static_cast<CFPropertyListRef*>(outData) = value;
    *outDataSize = sizeof(CFPropertyListRef);
    return kAudioHardwareNoError;
}

} // namespace sendspin
