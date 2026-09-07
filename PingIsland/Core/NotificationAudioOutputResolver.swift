import CoreAudio
import Foundation

/// Pins each notification to the output that is already available to this Mac.
/// This snapshots the route before playback starts, so opening an `NSSound`
/// cannot invite an automatic Bluetooth handoff from another Apple device.
nonisolated enum NotificationAudioOutputResolver {
    struct Device: Equatable {
        let id: AudioDeviceID
        let uid: String?
        let transportType: UInt32
        let outputChannelCount: UInt32
        let isAlive: Bool
        let hasSpeakerTerminal: Bool
    }

    // HAL can report either the legacy four-character terminal constants or
    // USB Audio output terminal codes. The latter use 0x0302 for headphones.
    private static let usbSpeakerTerminalTypes: Set<UInt32> = [
        0x0301, // Speaker
        0x0304, // Desktop speaker
        0x0305, // Room speaker
        0x0306, // Communication speaker
        0x0307, // Low-frequency effects speaker
    ]

    static func isSpeakerTerminalType(_ terminalType: UInt32) -> Bool {
        terminalType == kAudioStreamTerminalTypeSpeaker
            || terminalType == kAudioStreamTerminalTypeLFESpeaker
            || usbSpeakerTerminalTypes.contains(terminalType)
    }

    static func preferredDeviceUID(
        defaultDeviceID: AudioDeviceID?,
        devices: [Device]
    ) -> String? {
        if let defaultDeviceID,
           let current = devices.first(where: { $0.id == defaultDeviceID }),
           isUsable(current) {
            // Bluetooth is valid here only when CoreAudio already reports that
            // device alive on this Mac. Pinning its UID does not request a new route.
            return current.uid
        }

        return devices.first { device in
            isUsable(device)
                && device.transportType == kAudioDeviceTransportTypeBuiltIn
                && device.hasSpeakerTerminal
        }?.uid
    }

    static func outputDeviceUID() -> String? {
        let defaultDeviceID = defaultOutputDeviceID()
        let devices = allDeviceIDs().map { deviceID in
            Device(
                id: deviceID,
                uid: deviceUID(of: deviceID),
                transportType: transportType(of: deviceID) ?? 0,
                outputChannelCount: outputChannelCount(of: deviceID),
                isAlive: deviceIsAlive(deviceID),
                hasSpeakerTerminal: hasSpeakerTerminal(on: deviceID)
            )
        }
        return preferredDeviceUID(defaultDeviceID: defaultDeviceID, devices: devices)
    }

    private static func isUsable(_ device: Device) -> Bool {
        device.isAlive
            && device.outputChannelCount > 0
            && !(device.uid?.isEmpty ?? true)
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr,
              size >= MemoryLayout<AudioDeviceID>.stride,
              Int(size) % MemoryLayout<AudioDeviceID>.stride == 0 else { return [] }

        var deviceIDs = [AudioDeviceID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioDeviceID>.stride
        )
        let status = deviceIDs.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, bytes.baseAddress!
            )
        }
        return status == noErr ? deviceIDs : []
    }

    private static func transportType(of deviceID: AudioDeviceID) -> UInt32? {
        readUInt32(
            from: deviceID,
            selector: kAudioDevicePropertyTransportType,
            scope: kAudioObjectPropertyScopeGlobal
        )
    }

    private static func deviceIsAlive(_ deviceID: AudioDeviceID) -> Bool {
        readUInt32(
            from: deviceID,
            selector: kAudioDevicePropertyDeviceIsAlive,
            scope: kAudioObjectPropertyScopeGlobal
        ) == 1
    }

    private static func readUInt32(
        from objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func deviceUID(of deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func hasSpeakerTerminal(on deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioStreamID>.stride,
              Int(size) % MemoryLayout<AudioStreamID>.stride == 0 else { return false }

        var streamIDs = [AudioStreamID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioStreamID>.stride
        )
        let status = streamIDs.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bytes.baseAddress!)
        }
        guard status == noErr else { return false }
        return streamIDs.contains { streamID in
            terminalType(of: streamID).map(isSpeakerTerminalType) == true
        }
    }

    private static func terminalType(of streamID: AudioStreamID) -> UInt32? {
        readUInt32(
            from: streamID,
            selector: kAudioStreamPropertyTerminalType,
            scope: kAudioObjectPropertyScopeGlobal
        )
    }

    private static func outputChannelCount(of deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return 0 }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, storage) == noErr else {
            return 0
        }
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        guard let buffersOffset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers),
              Int(list.pointee.mNumberBuffers) <= (Int(size) - buffersOffset) / MemoryLayout<AudioBuffer>.stride else {
            return 0
        }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + $1.mNumberChannels }
    }
}
