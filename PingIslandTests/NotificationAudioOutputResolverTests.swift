import CoreAudio
import XCTest
@testable import Ping_Island

@MainActor
final class NotificationAudioOutputResolverTests: XCTestCase {
    private typealias Device = NotificationAudioOutputResolver.Device

    func testKeepsAirPodsWhenTheyAreAlreadyTheLiveMacOutput() {
        let devices = [
            device(id: 10, uid: "airpods", transport: kAudioDeviceTransportTypeBluetooth, speaker: false),
            device(id: 20, uid: "speakers"),
        ]

        XCTAssertEqual(
            NotificationAudioOutputResolver.preferredDeviceUID(defaultDeviceID: 10, devices: devices),
            "airpods"
        )
    }

    func testPinsAnyLiveCurrentMacOutputWithoutChangingTheSystemRoute() {
        let devices = [
            device(id: 10, uid: "usb-interface", transport: kAudioDeviceTransportTypeUSB, speaker: false),
            device(id: 20, uid: "speakers"),
        ]

        XCTAssertEqual(
            NotificationAudioOutputResolver.preferredDeviceUID(defaultDeviceID: 10, devices: devices),
            "usb-interface"
        )
    }

    func testUnavailableDefaultAirPodsFallBackToBuiltInSpeakers() {
        let devices = [
            device(
                id: 10,
                uid: "airpods",
                transport: kAudioDeviceTransportTypeBluetooth,
                alive: false,
                speaker: false
            ),
            device(id: 20, uid: "speakers"),
        ]

        XCTAssertEqual(
            NotificationAudioOutputResolver.preferredDeviceUID(defaultDeviceID: 10, devices: devices),
            "speakers"
        )
    }

    func testInvalidCurrentOutputDoesNotSelectAnotherBluetoothDevice() {
        let devices = [
            device(id: 10, uid: "input-only", channels: 0, speaker: false),
            device(id: 15, uid: "other-airpods", transport: kAudioDeviceTransportTypeBluetooth, speaker: false),
            device(id: 20, uid: "speakers"),
        ]

        XCTAssertEqual(
            NotificationAudioOutputResolver.preferredDeviceUID(defaultDeviceID: 10, devices: devices),
            "speakers"
        )
    }

    func testMissingSafeFallbackSkipsPlaybackInsteadOfRequestingAnotherRoute() {
        let devices = [
            device(
                id: 10,
                uid: "airpods",
                transport: kAudioDeviceTransportTypeBluetooth,
                alive: false,
                speaker: false
            ),
            device(id: 20, uid: "wired-headphones", speaker: false),
        ]

        XCTAssertNil(NotificationAudioOutputResolver.preferredDeviceUID(defaultDeviceID: 10, devices: devices))
        XCTAssertNil(NotificationAudioOutputResolver.preferredDeviceUID(defaultDeviceID: nil, devices: []))
    }

    func testRecognizesLegacyAndUSBFamilySpeakerTerminalsButNotHeadphones() {
        XCTAssertTrue(NotificationAudioOutputResolver.isSpeakerTerminalType(kAudioStreamTerminalTypeSpeaker))
        XCTAssertTrue(NotificationAudioOutputResolver.isSpeakerTerminalType(0x0301))
        XCTAssertTrue(NotificationAudioOutputResolver.isSpeakerTerminalType(0x0304))
        XCTAssertFalse(NotificationAudioOutputResolver.isSpeakerTerminalType(kAudioStreamTerminalTypeHeadphones))
        XCTAssertFalse(NotificationAudioOutputResolver.isSpeakerTerminalType(0x0302))
    }

    func testEmptyUIDMakesADeviceUnusable() {
        let devices = [
            device(id: 10, uid: nil),
            device(id: 20, uid: ""),
        ]

        XCTAssertNil(NotificationAudioOutputResolver.preferredDeviceUID(defaultDeviceID: 10, devices: devices))
    }

    private func device(
        id: AudioDeviceID,
        uid: String?,
        transport: UInt32 = kAudioDeviceTransportTypeBuiltIn,
        channels: UInt32 = 2,
        alive: Bool = true,
        speaker: Bool = true
    ) -> Device {
        Device(
            id: id,
            uid: uid,
            transportType: transport,
            outputChannelCount: channels,
            isAlive: alive,
            hasSpeakerTerminal: speaker
        )
    }
}
