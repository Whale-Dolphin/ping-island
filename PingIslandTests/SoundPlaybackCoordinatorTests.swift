import XCTest
@testable import Ping_Island

@MainActor
final class SoundPlaybackCoordinatorTests: XCTestCase {
    func testCurrentMacOutputIsPinnedBeforePlayback() {
        let sound = RecordingSound()
        let coordinator = SoundPlaybackCoordinator(outputDeviceUID: { "currently-connected-airpods" })

        XCTAssertTrue(coordinator.play(sound, volume: 0.4))
        XCTAssertEqual(sound.deviceUIDAtPlayback, "currently-connected-airpods")
        XCTAssertEqual(sound.volume, 0.4)
        XCTAssertEqual(sound.playCount, 1)
    }

    func testResolvedOutputReplacesAStaleDeviceInsteadOfFollowingAutomaticRouting() {
        let sound = RecordingSound()
        sound.outputDeviceUID = "stale-output"
        let coordinator = SoundPlaybackCoordinator(outputDeviceUID: { "current-mac-output" })

        XCTAssertTrue(coordinator.play(sound, volume: 0.5))
        XCTAssertEqual(sound.deviceUIDAtPlayback, "current-mac-output")
    }

    func testZeroNegativeAndNonfiniteVolumeNeverStartPlaybackOrResolveDevices() {
        let sound = RecordingSound()
        var resolutions = 0
        let coordinator = SoundPlaybackCoordinator(outputDeviceUID: {
            resolutions += 1
            return "speakers"
        })

        for volume: Float in [0, -0.1, .nan, .infinity] {
            XCTAssertFalse(coordinator.play(sound, volume: volume))
        }
        XCTAssertEqual(sound.playCount, 0)
        XCTAssertEqual(resolutions, 0)
    }

    func testDisabledSoundsNeverStartPlaybackOrResolveDevices() {
        let sound = RecordingSound()
        let coordinator = SoundPlaybackCoordinator(
            isEnabled: { false },
            outputDeviceUID: {
                XCTFail("Disabled sounds must not query devices")
                return "speakers"
            }
        )

        XCTAssertFalse(coordinator.play(sound, volume: 1))
        XCTAssertEqual(sound.playCount, 0)
    }

    func testMissingSafeDeviceNeverFallsBackToAutomaticOutput() {
        for uid: String? in [nil, ""] {
            let sound = RecordingSound()
            let coordinator = SoundPlaybackCoordinator(outputDeviceUID: { uid })

            XCTAssertFalse(coordinator.play(sound, volume: 1))
            XCTAssertEqual(sound.playCount, 0)
            XCTAssertNil(sound.deviceUIDAtPlayback)
        }
    }

    func testMuteStopsTheActiveNotification() {
        let sound = RecordingSound()
        let coordinator = SoundPlaybackCoordinator(outputDeviceUID: { "speakers" })
        XCTAssertTrue(coordinator.play(sound, volume: 0.5))

        XCTAssertFalse(coordinator.play(sound, volume: 0))
        XCTAssertEqual(sound.playCount, 1)
        XCTAssertEqual(sound.stopCount, 1)
        XCTAssertFalse(sound.isPlaying)
    }

    func testOldCompletionCannotClearTheCurrentSound() {
        let first = RecordingSound()
        let second = RecordingSound()
        let coordinator = SoundPlaybackCoordinator(outputDeviceUID: { "speakers" })
        XCTAssertTrue(coordinator.play(first, volume: 0.5))
        XCTAssertTrue(coordinator.play(second, volume: 0.5))
        XCTAssertEqual(first.stopCount, 1)

        coordinator.clearIfActive(first)
        coordinator.stop()
        XCTAssertEqual(second.stopCount, 1)
    }

    func testReplayingTheSameSoundRestartsItAndClampsVolume() {
        let sound = RecordingSound()
        let coordinator = SoundPlaybackCoordinator(outputDeviceUID: { "speakers" })
        XCTAssertTrue(coordinator.play(sound, volume: 0.5))
        XCTAssertTrue(coordinator.play(sound, volume: 2))

        XCTAssertEqual(sound.playCount, 2)
        XCTAssertEqual(sound.stopCount, 1)
        XCTAssertEqual(sound.volume, 1)
    }

    private final class RecordingSound: CoordinatedSound {
        var isPlaying = false
        var volume: Float = 0
        var outputDeviceUID: String?
        private(set) var deviceUIDAtPlayback: String?
        private(set) var playCount = 0
        private(set) var stopCount = 0

        func play() -> Bool {
            deviceUIDAtPlayback = outputDeviceUID
            playCount += 1
            isPlaying = true
            return true
        }

        func stop() -> Bool {
            stopCount += 1
            isPlaying = false
            return true
        }
    }
}
