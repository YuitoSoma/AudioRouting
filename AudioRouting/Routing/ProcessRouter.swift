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
        try check(AudioHardwareCreateProcessTap(tap, &tapID), "AudioHardwareCreateProcessTap")

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
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
                  "AudioHardwareCreateAggregateDevice")

        let skipInputBuffers = Self.inputStreamCount(of: device.objectID)
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) { _, input, _, output, _ in
            AudioBufferCopy.copy(from: input, to: output, skipInputBuffers: skipInputBuffers)
        }, "AudioDeviceCreateIOProcIDWithBlock")

        try check(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")
        logger.info("routing \(self.bundleID) -> \(self.deviceUID)")
    }

    /// Safe to call more than once.
    func stop() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw CoreAudioError(status: status, operation: operation) }
    }

    private static func inputStreamCount(of device: AudioObjectID) -> Int {
        let streams: [AudioStreamID] = (try? CoreAudioProperty.array(
            device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput
        )) ?? []
        return streams.count
    }
}

@MainActor
struct ProcessRouterFactory: AudioRouteFactory {
    func startRoute(bundleID: String, processObjectIDs: [AudioObjectID], device: AudioOutputDevice) throws -> ActiveAudioRoute {
        try ProcessRouter(bundleID: bundleID, processObjectIDs: processObjectIDs, device: device)
    }
}
