import CoreAudio
import XCTest
@testable import AudioRouting

/// Real Core Audio: taps an `afplay` process, routes it through an aggregate device to the default
/// output, and checks that nothing is left behind. Skipped (not failed) when the environment
/// can't run it: no "System Audio Recording" permission, no output device, or afplay not seen.
@MainActor
final class IntegrationTests: XCTestCase {
    private var player: Process?
    private var router: ProcessRouter?
    private var toneURL: URL?

    override func tearDown() async throws {
        router?.stop()
        router = nil
        if let player, player.isRunning {
            player.terminate()
            player.waitUntilExit()
        }
        player = nil
        if let toneURL { try? FileManager.default.removeItem(at: toneURL) }
    }

    // MARK: Without permission (device and process lists need no capture permission)

    func testCoreAudioSystemListsDefaultOutputDevice() throws {
        let system = CoreAudioSystem()
        let devices = system.outputDevices()
        guard let defaultUID = system.defaultOutputDeviceUID() else { throw XCTSkip("出力デバイスがないためスキップ") }

        XCTAssertTrue(devices.contains { $0.uid == defaultUID }, "default output \(defaultUID) not in \(devices.map(\.uid))")
        XCTAssertFalse(devices.contains { $0.uid.hasPrefix(AudioRoutingConstants.aggregateUIDPrefix) })
        XCTAssertTrue(devices.allSatisfy { !$0.name.isEmpty })
    }

    func testProcessMonitorSeesAfplayStartAndStopPlaying() async throws {
        let system = CoreAudioSystem()
        guard system.defaultOutputDeviceUID() != nil else { throw XCTSkip("出力デバイスがないためスキップ") }
        let monitor = AudioProcessMonitor(system: system)
        var changes = 0
        monitor.onChange = { changes += 1 }

        let process = try await startAfplay(system: system)
        let pid = process.pid
        try await waitUntil("afplay reported as playing") {
            monitor.processes.contains { $0.pid == pid && $0.isRunningOutput }
        }
        XCTAssertGreaterThan(changes, 0, "process listener should have fired")

        player?.terminate()
        player?.waitUntilExit()
        try await waitUntil("afplay gone or stopped") {
            !monitor.processes.contains { $0.pid == pid && $0.isRunningOutput }
        }
    }

    func testRoutesAfplayThroughTapAndAggregateAndCleansUp() async throws {
        guard TCCAudioCapturePermission().status == .authorized else {
            throw XCTSkip("「システム音声の録音」が許可されていないためスキップ")
        }
        let system = CoreAudioSystem()
        guard let defaultUID = system.defaultOutputDeviceUID(),
              let device = system.outputDevices().first(where: { $0.uid == defaultUID })
        else { throw XCTSkip("出力デバイスがないためスキップ") }

        let baselineTaps = AudioDiagnostics.tapCount()
        let baselineAggregates = AudioDiagnostics.ownAggregateCount()

        let process = try await startAfplay(system: system)

        let router = try ProcessRouter(bundleID: "afplay", processObjectIDs: [process.objectID], device: device)
        self.router = router
        XCTAssertNotEqual(router.tapID, AudioObjectID(kAudioObjectUnknown))
        XCTAssertNotEqual(router.aggregateID, AudioObjectID(kAudioObjectUnknown))
        XCTAssertEqual(AudioDiagnostics.tapCount(), baselineTaps + 1)
        XCTAssertEqual(AudioDiagnostics.ownAggregateCount(), baselineAggregates + 1)

        try await Task.sleep(for: .milliseconds(500))
        let running: UInt32 = try CoreAudioProperty.value(
            router.aggregateID, kAudioDevicePropertyDeviceIsRunningSomewhere, initial: 0
        )
        XCTAssertEqual(running, 1, "aggregate device IO should be running")
        let gotSignal = await AudioDiagnostics.waitUntil(seconds: 3) { router.meter.peak > 0.0005 }
        XCTAssertTrue(gotSignal, "tapped audio should reach the device (peak \(router.meter.peak))")

        router.stop()
        router.stop() // second stop is a no-op

        XCTAssertEqual(router.teardownErrors.map(\.description), [])
        // The HAL may update its object lists shortly after the destroy calls return.
        let cleanedUp = await AudioDiagnostics.waitUntil(seconds: 3) {
            AudioDiagnostics.counts() == (baselineTaps, baselineAggregates)
        }
        XCTAssertTrue(cleanedUp, "tap or aggregate leaked: \(AudioDiagnostics.counts()) vs \(baselineTaps)/\(baselineAggregates)")
    }

    func testRouterToMissingDeviceLeavesNothingBehind() async throws {
        guard TCCAudioCapturePermission().status == .authorized else {
            throw XCTSkip("「システム音声の録音」が許可されていないためスキップ")
        }
        let baselineTaps = AudioDiagnostics.tapCount()
        let baselineAggregates = AudioDiagnostics.ownAggregateCount()
        let missingDevice = AudioOutputDevice(objectID: 0, uid: "local.audiorouting.no-such-device", name: "none")

        // Whether the HAL refuses this or not, nothing may be left behind afterwards.
        if let router = try? ProcessRouter(bundleID: "none", processObjectIDs: [], device: missingDevice) {
            router.stop()
        }

        let cleanedUp = await AudioDiagnostics.waitUntil(seconds: 3) {
            AudioDiagnostics.counts() == (baselineTaps, baselineAggregates)
        }
        XCTAssertTrue(cleanedUp, "tap or aggregate leaked: \(AudioDiagnostics.counts()) vs \(baselineTaps)/\(baselineAggregates)")
    }

    // MARK: Helpers

    /// Polls for up to 5 s, letting the main queue run Core Audio listener callbacks in between.
    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<50 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("timed out waiting: \(what)")
    }

    private func startAfplay(system: CoreAudioSystem) async throws -> AudioProcess {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audiorouting-tone-\(UUID().uuidString).wav")
        try AudioDiagnostics.toneWAV(seconds: 5).write(to: url)
        toneURL = url

        let player = try AudioDiagnostics.startAfplay(url)
        self.player = player

        for _ in 0..<50 {
            if let process = system.audioProcesses().first(where: { $0.pid == player.processIdentifier }) {
                return process
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw XCTSkip("afplay の音声プロセスが見つからないためスキップ")
    }
}
