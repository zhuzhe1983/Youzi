import CoreAudio
import Foundation
// Read-only capability inspection: no IOProc, audio engine, recording, or property writes.
func readUInt(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(object, &address) else { return nil }
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value
}
func fourCC(_ value: UInt32?) -> String {
    guard let value else { return "unavailable" }
    return String(bytes: [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)], encoding: .ascii) ?? "unknown"
}
for (name, selector) in [("input", kAudioHardwarePropertyDefaultInputDevice), ("output", kAudioHardwarePropertyDefaultOutputDevice)] {
    guard let device = readUInt(AudioObjectID(kAudioObjectSystemObject), selector), device != kAudioObjectUnknown else { print("\(name): unavailable"); continue }
    print("default \(name) transport: \(fourCC(readUInt(device, kAudioDevicePropertyTransportType)))")
    for (scopeName, scope) in [("global", kAudioObjectPropertyScopeGlobal), ("input", kAudioObjectPropertyScopeInput)] {
        for (propertyName, property) in [("vadEnable", kAudioDevicePropertyVoiceActivityDetectionEnable), ("vadState", kAudioDevicePropertyVoiceActivityDetectionState)] {
            var address = AudioObjectPropertyAddress(mSelector: property, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            let exists = AudioObjectHasProperty(device, &address)
            var writable: DarwinBoolean = false
            let status = exists ? AudioObjectIsPropertySettable(device, &address, &writable) : OSStatus(-1)
            let value = exists ? readUInt(device, property, scope).map(String.init) ?? "unreadable" : "n/a"
            print("  \(scopeName) \(propertyName): exists=\(exists) writable=\(status == noErr && writable.boolValue) value=\(value)")
        }
    }
}
