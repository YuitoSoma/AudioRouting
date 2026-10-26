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

    func testRoutesAfplayThroughTapAndAggregateAndCleansUp() async throws {
        guard TCCAudioCapturePermission().status == .authorized else {
            throw XCTSkip("「システム音声の録音」が許可されていないためスキップ")
        }
        let system = CoreAudioSystem()
        guard let defaultUID = system.defaultOutputDeviceUID(),
              let device = system.outputDevices().first(where: { $0.uid == defaultUID })
        else { throw XCTSkip("出力デバイスがないためスキップ") }

        let baselineTaps = Self.tapCount()
        let baselineAggregates = Self.ownAggregateCount()

        let process = try await startAfplay(system: system)

        let router = try ProcessRouter(bundleID: "afplay", processObjectIDs: [process.objectID], device: device)
        self.router = router
        XCTAssertNotEqual(router.tapID, AudioObjectID(kAudioObjectUnknown))
        XCTAssertNotEqual(router.aggregateID, AudioObjectID(kAudioObjectUnknown))
        XCTAssertEqual(Self.tapCount(), baselineTaps + 1)
        XCTAssertEqual(Self.ownAggregateCount(), baselineAggregates + 1)

        try await Task.sleep(for: .milliseconds(500))
        let running: UInt32 = try CoreAudioProperty.value(
            router.aggregateID, kAudioDevicePropertyDeviceIsRunningSomewhere, initial: 0
        )
        XCTAssertEqual(running, 1, "aggregate device IO should be running")

        router.stop()
        router.stop() // second stop is a no-op

        XCTAssertEqual(Self.tapCount(), baselineTaps, "process tap leaked")
        XCTAssertEqual(Self.ownAggregateCount(), baselineAggregates, "aggregate device leaked")
    }

    func testRouterToMissingDeviceLeavesNothingBehind() throws {
        guard TCCAudioCapturePermission().status == .authorized else {
            throw XCTSkip("「システム音声の録音」が許可されていないためスキップ")
        }
        let baselineTaps = Self.tapCount()
        let baselineAggregates = Self.ownAggregateCount()
        let missingDevice = AudioOutputDevice(objectID: 0, uid: "local.audiorouting.no-such-device", name: "none")

        // Whether the HAL refuses this or not, nothing may be left behind afterwards.
        if let router = try? ProcessRouter(bundleID: "none", processObjectIDs: [], device: missingDevice) {
            router.stop()
        }

        XCTAssertEqual(Self.tapCount(), baselineTaps)
        XCTAssertEqual(Self.ownAggregateCount(), baselineAggregates)
    }

    // MARK: Helpers

    private func startAfplay(system: CoreAudioSystem) async throws -> AudioProcess {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audiorouting-tone-\(UUID().uuidString).wav")
        try Self.toneWAV(seconds: 5).write(to: url)
        toneURL = url

        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["-v", "0.05", url.path]
        try player.run()
        self.player = player

        for _ in 0..<50 {
            if let process = system.audioProcesses().first(where: { $0.pid == player.processIdentifier }) {
                return process
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw XCTSkip("afplay の音声プロセスが見つからないためスキップ")
    }

    private static func tapCount() -> Int {
        let taps: [AudioObjectID] = (try? CoreAudioProperty.array(
            CoreAudioProperty.systemObject, kAudioHardwarePropertyTapList
        )) ?? []
        return taps.count
    }

    private static func ownAggregateCount() -> Int {
        let devices: [AudioObjectID] = (try? CoreAudioProperty.array(
            CoreAudioProperty.systemObject, kAudioHardwarePropertyDevices
        )) ?? []
        return devices.filter {
            ((try? CoreAudioProperty.string($0, kAudioDevicePropertyDeviceUID)) ?? "")
                .hasPrefix(AudioRoutingConstants.aggregateUIDPrefix)
        }.count
    }

    /// 16-bit mono 440 Hz sine, quiet.
    private static func toneWAV(seconds: Int, sampleRate: Int = 44_100) -> Data {
        let frames = seconds * sampleRate
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + frames * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(UInt32(sampleRate)); append(UInt32(sampleRate * 2))
        append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(frames * 2))
        for frame in 0..<frames {
            append(Int16(sin(Double(frame) * 2 * .pi * 440 / Double(sampleRate)) * 3000))
        }
        return data
    }
}
