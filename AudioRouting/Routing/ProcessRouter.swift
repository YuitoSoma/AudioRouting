import AudioToolbox
import CoreAudio
import Foundation
import os

/// Sends one app's audio to one output device:
/// process tap (original output muted) -> private aggregate device (output device + tap) -> IOProc
/// copying the tap's input to the device's output.
///
/// `stop()` destroys the IOProc, the aggregate device and the tap, in that order. Leaked taps pile
/// up in the HAL, so every failure path in `start` also cleans up what it created. Both the tap and
/// the aggregate are private, so the HAL also removes them if this process dies.
@MainActor
final class ProcessRouter: ActiveAudioRoute {
    let bundleID: String
    let deviceUID: String

    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    /// Peak level of the audio written to the device, for diagnostics.
    let meter = PeakMeter()
    private let ioQueue = DispatchQueue(label: "local.audiorouting.ioproc", qos: .userInteractive)
    private let logger = Logger(subsystem: "local.audiorouting", category: "ProcessRouter")

    init(bundleID: String, processObjectIDs: [AudioObjectID], device: AudioOutputDevice) throws {
        self.bundleID = bundleID
        deviceUID = device.uid
        do {
            try start(processObjectIDs: processObjectIDs, device: device)
        } catch {
            stop()
            throw error
        }
    }

    private func start(processObjectIDs: [AudioObjectID], device: AudioOutputDevice) throws {
        let tap = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        tap.uuid = UUID()
        tap.name = "AudioRouting \(bundleID)"
        tap.muteBehavior = .mutedWhenTapped
        tap.isPrivate = true
        try call("AudioHardwareCreateProcessTap") { AudioHardwareCreateProcessTap(tap, &tapID) }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AudioRouting \(bundleID)",
            kAudioAggregateDeviceUIDKey: AudioRoutingConstants.aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: device.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: device.uid],
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tap.uuid.uuidString,
                ],
            ],
        ]
        try call("AudioHardwareCreateAggregateDevice") {
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        }

        let skipInputBuffers = Self.inputStreamCount(of: device.objectID)
        let ioBlock = Self.makeIOBlock(skipInputBuffers: skipInputBuffers, meter: meter)
        try call("AudioDeviceCreateIOProcIDWithBlock") {
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue, ioBlock)
        }

        try call("AudioDeviceStart") { AudioDeviceStart(aggregateID, ioProcID) }
        logger.info("routing \(self.bundleID) -> \(self.deviceUID)")
    }

    /// Core Audio calls that failed during the last `stop()`, for diagnostics.
    private(set) var teardownErrors: [CoreAudioError] = []

    /// Safe to call more than once.
    func stop() {
        teardownErrors = []
        if let ioProcID {
            record("AudioDeviceStop") { AudioDeviceStop(aggregateID, ioProcID) }
            record("AudioDeviceDestroyIOProcID") { AudioDeviceDestroyIOProcID(aggregateID, ioProcID) }
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            record("AudioHardwareDestroyAggregateDevice") { AudioHardwareDestroyAggregateDevice(aggregateID) }
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            record("AudioHardwareDestroyProcessTap") { AudioHardwareDestroyProcessTap(tapID) }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func record(_ operation: String, _ body: () -> OSStatus) {
        let status = timed(operation, body)
        guard status != noErr else { return }
        let error = CoreAudioError(status: status, operation: operation)
        teardownErrors.append(error)
        logger.error("\(self.bundleID): \(error)")
    }

    /// HAL calls run on the main actor; log any that stall so hangs can be traced.
    private func timed(_ operation: String, _ body: () -> OSStatus) -> OSStatus {
        let start = ContinuousClock.now
        let status = body()
        let elapsed = ContinuousClock.now - start
        if elapsed > .milliseconds(200) {
            logger.warning("\(self.bundleID): \(operation) took \(elapsed) (status \(status))")
        }
        return status
    }



    /// Built outside the main actor on purpose: a closure written inside this @MainActor class
    /// would be main-actor isolated, and Swift 6 traps when the HAL calls it on its IO thread.
    nonisolated static func makeIOBlock(skipInputBuffers: Int, meter: PeakMeter) -> AudioDeviceIOBlock {
        { _, input, _, output, _ in
            AudioBufferCopy.copy(from: input, to: output, skipInputBuffers: skipInputBuffers)
            meter.record(AudioBufferCopy.peak(of: output))
        }
    }

    private func call(_ operation: String, _ body: () -> OSStatus) throws {
        let status = timed(operation, body)
        guard status == noErr else { throw CoreAudioError(status: status, operation: operation) }
    }


    private static func inputStreamCount(of device: AudioObjectID) -> Int {
        let streams: [AudioStreamID] = (try? CoreAudioProperty.array(
            device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput
        )) ?? []
        return streams.count
    }
}

/// Highest absolute sample level seen since the last `reset()`. Written from the IO thread and read
/// from the main thread without a lock: an aligned Float32 store is atomic on arm64, and a slightly
/// stale value is fine for a level indicator.
final class PeakMeter: @unchecked Sendable {
    private let storage = UnsafeMutablePointer<Float32>.allocate(capacity: 1)

    init() { storage.initialize(to: 0) }
    deinit { storage.deallocate() }

    var peak: Float32 { storage.pointee }
    func reset() { storage.pointee = 0 }
    func record(_ level: Float32) {
        if level > storage.pointee { storage.pointee = level }
    }
}

@MainActor
struct ProcessRouterFactory: AudioRouteFactory {
    func startRoute(bundleID: String, processObjectIDs: [AudioObjectID], device: AudioOutputDevice) throws -> ActiveAudioRoute {
        try ProcessRouter(bundleID: bundleID, processObjectIDs: processObjectIDs, device: device)
    }
}
