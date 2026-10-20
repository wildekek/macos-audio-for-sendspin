// Copyright (c) macOS Audio for Sendspin authors
// Licensed under the Apache License, Version 2.0
//
// Audio Server plug-in providing the "Sendspin" output device. Apps play into its
// output; the macOS Audio for Sendspin app captures the same audio from its input
// (loopback) and streams it to Sendspin players.

#include "LoopbackHandler.hpp"
#include "LoopbackStream.hpp"

#include <aspl/Driver.hpp>

#include <CoreAudio/AudioServerPlugIn.h>

#include <algorithm>
#include <climits>
#include <string>

namespace {

constexpr UInt32 DefaultSampleRate = 48000;
constexpr UInt32 ChannelCount = 2;

// Custom device property 'sslt': output presentation latency in frames (CFNumber),
// set by the macOS Audio for Sendspin app to the players' playback lead.
constexpr AudioObjectPropertySelector PresentationLatencySelector = 'sslt';
constexpr UInt32 MaxPresentationLatencySeconds = 5;

// file:// URL of the device icon inside this plug-in's bundle, wherever it's installed.
std::string IconURL()
{
    CFBundleRef bundle = CFBundleGetBundleWithIdentifier(CFSTR("eu.vooijs.MacOSAudioForSendspin.Driver"));
    if (!bundle) {
        return "";
    }
    CFURLRef relative = CFBundleCopyResourceURL(bundle, CFSTR("SendspinDevice"), CFSTR("icns"), nullptr);
    if (!relative) {
        return "";
    }
    CFURLRef url = CFURLCopyAbsoluteURL(relative);
    CFRelease(relative);
    char buffer[PATH_MAX * 2] = {};
    const bool ok = CFStringGetCString(CFURLGetString(url), buffer, sizeof(buffer), kCFStringEncodingUTF8);
    CFRelease(url);
    return ok ? buffer : "";
}

std::shared_ptr<aspl::Driver> CreateDriver()
{
    auto context = std::make_shared<aspl::Context>();

    aspl::DeviceParameters deviceParams;
    deviceParams.Name = "Sendspin";
    deviceParams.Manufacturer = "macOS Audio for Sendspin";
    deviceParams.DeviceUID = "eu.vooijs.MacOSAudioForSendspin.Device";
    deviceParams.ModelUID = "eu.vooijs.MacOSAudioForSendspin.Model";
    deviceParams.FirmwareVersion = DRIVER_VERSION;
    deviceParams.ConfigurationApplicationBundleID = "eu.vooijs.MacOSAudioForSendspin";
    deviceParams.IconURL = IconURL();
    deviceParams.SampleRate = DefaultSampleRate;
    deviceParams.ChannelCount = ChannelCount;
    deviceParams.CanBeDefault = true;
    // Alerts and UI sounds shouldn't play through the house speakers.
    deviceParams.CanBeDefaultForSystemSounds = false;

    auto device = std::make_shared<aspl::Device>(context, deviceParams);

    // The app switches the rate to match the stream it sends to the speakers.
    std::vector<AudioValueRange> rates;
    for (Float64 rate : sendspin::SupportedSampleRates) {
        rates.push_back({rate, rate});
    }
    device->SetAvailableSampleRatesAsync(rates);

    // Output with volume + mute, so the volume keys and Control Center work.
    aspl::StreamParameters outputParams;
    outputParams.Direction = aspl::Direction::Output;
    outputParams.Format = sendspin::Float32Format(DefaultSampleRate, ChannelCount);
    auto outputStream = std::make_shared<sendspin::LoopbackStream>(context, device, outputParams);
    device->AddStreamAsync(outputStream);
    outputStream->AttachVolumeControl(device->AddVolumeControlAsync(kAudioObjectPropertyScopeOutput));
    outputStream->AttachMuteControl(device->AddMuteControlAsync(kAudioObjectPropertyScopeOutput));

    // The app sets how far behind the speakers play (their buffer), and we report it
    // as output latency, so video players delay the picture to keep lip sync.
    std::weak_ptr<aspl::Stream> weakOutput = outputStream;
    device->RegisterCustomProperty(
        PresentationLatencySelector,
        [weakOutput]() -> CFPropertyListRef {
            auto stream = weakOutput.lock();
            SInt32 frames = stream ? SInt32(stream->GetLatency()) : 0;
            return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &frames);
        },
        [weakOutput](CFPropertyListRef value) {
            SInt32 frames = 0;
            if (!value || CFGetTypeID(value) != CFNumberGetTypeID() ||
                !CFNumberGetValue(CFNumberRef(value), kCFNumberSInt32Type, &frames)) {
                return;
            }
            const Float64 maxRate = sendspin::SupportedSampleRates.back();
            frames = std::clamp<SInt32>(frames, 0, SInt32(MaxPresentationLatencySeconds * maxRate));
            if (auto stream = weakOutput.lock(); stream && stream->GetLatency() != UInt32(frames)) {
                stream->SetLatencyAsync(UInt32(frames));
            }
        });

    // Input carrying the loopback that the app captures.
    aspl::StreamParameters inputParams;
    inputParams.Direction = aspl::Direction::Input;
    inputParams.Format = sendspin::Float32Format(DefaultSampleRate, ChannelCount);
    device->AddStreamAsync(std::make_shared<sendspin::LoopbackStream>(context, device, inputParams));

    auto handler = std::make_shared<sendspin::LoopbackHandler>(ChannelCount);
    device->SetControlHandler(handler);
    device->SetIOHandler(handler);

    auto plugin = std::make_shared<aspl::Plugin>(context);
    plugin->AddDevice(device);

    return std::make_shared<aspl::Driver>(context, plugin);
}

} // namespace

extern "C" void* SendspinDriverEntryPoint(CFAllocatorRef, CFUUIDRef typeUUID)
{
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        return nullptr;
    }

    // Static, so the driver and its object tree live as long as the plug-in.
    static std::shared_ptr<aspl::Driver> driver = CreateDriver();

    return driver->GetReference();
}
