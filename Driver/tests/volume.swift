// Read or set the output volume / mute of a CoreAudio device by name.
//
//   swift Driver/tests/volume.swift Sendspin            # print volume and mute
//   swift Driver/tests/volume.swift Sendspin 0.25       # set volume scalar
//   swift Driver/tests/volume.swift Sendspin mute|unmute

import CoreAudio
import Foundation

func property<T>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) -> T? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                             mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
}

func set<T>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: T) -> OSStatus {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeOutput,
                                             mElement: kAudioObjectPropertyElementMain)
    var value = value
    return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value)
}

func findDevice(named query: String) -> AudioObjectID? {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
    return ids.first { id in
        let name = property(id, kAudioObjectPropertyName, initial: "" as CFString) as String?
        return name == query
    }
}

let args = CommandLine.arguments.dropFirst()
guard let name = args.first, let device = findDevice(named: name) else {
    print("usage: volume.swift <device name> [scalar|mute|unmute]  (device not found)")
    exit(2)
}

switch args.dropFirst().first {
case "mute": print("set mute:", set(device, kAudioDevicePropertyMute, UInt32(1)))
case "unmute": print("set mute:", set(device, kAudioDevicePropertyMute, UInt32(0)))
case let value?:
    guard let scalar = Float32(value) else { print("bad volume \(value)"); exit(2) }
    print("set volume:", set(device, kAudioDevicePropertyVolumeScalar, scalar))
case nil:
    break
}

let volume = property(device, kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput,
                      initial: Float32(-1))
let muted = property(device, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, initial: UInt32(0))
print("\(name): volume \(volume.map { String($0) } ?? "n/a"), muted \(muted.map { $0 != 0 } ?? false)")
