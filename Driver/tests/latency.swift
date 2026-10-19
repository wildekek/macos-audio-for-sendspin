// Read or set the Sendspin device's presentation latency (custom property 'sslt'),
// and show the output latency apps see as a result.
//
//   swift Driver/tests/latency.swift            # print
//   swift Driver/tests/latency.swift 28800      # set to 28800 frames (600 ms at 48 kHz)

import CoreAudio
import Foundation

let presentationLatency: AudioObjectPropertySelector = 0x7373_6C74 // 'sslt'

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func sendspinDevice() -> AudioObjectID? {
    var uid = "eu.vooijs.SendspinForMac.Device" as CFString
    var device = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var addr = address(kAudioHardwarePropertyTranslateUIDToDevice)
    let status = withUnsafePointer(to: &uid) {
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                   UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
    }
    return status == noErr && device != 0 ? device : nil
}

func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32 {
    var addr = address(selector, scope)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : 0
}

func outputStream(_ device: AudioObjectID) -> AudioObjectID? {
    var addr = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size)
    var streams = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &streams)
    return streams.first
}

guard let device = sendspinDevice() else { print("Sendspin device not found"); exit(1) }

if let arg = CommandLine.arguments.dropFirst().first, let frames = Int32(arg) {
    var addr = address(presentationLatency)
    var number: CFPropertyList = frames as CFNumber
    let status = AudioObjectSetPropertyData(device, &addr, 0, nil,
                                            UInt32(MemoryLayout<CFPropertyList>.size), &number)
    print("set sslt=\(frames): status \(status)")
    Thread.sleep(forTimeInterval: 0.3) // the HAL applies latency changes asynchronously
}

var addr = address(presentationLatency)
var value: Unmanaged<CFPropertyList>?
var size = UInt32(MemoryLayout<CFPropertyList>.size)
let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value)
let current = (value?.takeRetainedValue() as? NSNumber)?.intValue
print("sslt: \(current.map(String.init) ?? "unreadable (status \(status))") frames")

let deviceLatency = uint32(device, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput)
let safety = uint32(device, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput)
let streamLatency = outputStream(device).map { uint32($0, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal) } ?? 0
print("output: device latency \(deviceLatency), stream latency \(streamLatency), safety offset \(safety) frames"
    + " → \(Double(deviceLatency + streamLatency + safety) / 48) ms")
