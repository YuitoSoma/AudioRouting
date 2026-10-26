import CoreAudio
import Foundation
import os

/// The real AudioSystem, backed by the Core Audio HAL.
@MainActor
final class CoreAudioSystem: AudioSystem {
    private let logger = Logger(subsystem: "local.audiorouting", category: "CoreAudioSystem")

    func outputDevices() -> [AudioOutputDevice] {
        let ids: [AudioObjectID]
        do {
            ids = try CoreAudioProperty.array(CoreAudioProperty.systemObject, kAudioHardwarePropertyDevices)
        } catch {
            logger.error("device list: \(error)")
            return []
        }
        return ids.compactMap { id in
            guard hasOutputStreams(id),
                  let uid = try? CoreAudioProperty.string(id, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix(AudioRoutingConstants.aggregateUIDPrefix)
            else { return nil }
            let name = (try? CoreAudioProperty.string(id, kAudioObjectPropertyName)) ?? uid
            return AudioOutputDevice(objectID: id, uid: uid, name: name)
        }
    }

    func defaultOutputDeviceUID() -> String? {
        guard let id: AudioObjectID = try? CoreAudioProperty.value(
            CoreAudioProperty.systemObject, kAudioHardwarePropertyDefaultOutputDevice,
            initial: AudioObjectID(kAudioObjectUnknown)
        ), id != kAudioObjectUnknown else { return nil }
        return try? CoreAudioProperty.string(id, kAudioDevicePropertyDeviceUID)
    }

    func audioProcesses() -> [AudioProcess] {
        let ids: [AudioObjectID]
        do {
            ids = try CoreAudioProperty.array(CoreAudioProperty.systemObject, kAudioHardwarePropertyProcessObjectList)
        } catch {
            logger.error("process list: \(error)")
            return []
        }
        return ids.compactMap { id in
            guard let pid: pid_t = try? CoreAudioProperty.value(id, kAudioProcessPropertyPID, initial: -1),
                  pid > 0
            else { return nil }
            let bundleID = (try? CoreAudioProperty.string(id, kAudioProcessPropertyBundleID)) ?? ""
            let running: UInt32 = (try? CoreAudioProperty.value(id, kAudioProcessPropertyIsRunningOutput, initial: 0)) ?? 0
            return AudioProcess(objectID: id, pid: pid, bundleID: bundleID, isRunningOutput: running != 0)
        }
    }

    func observeDevices(_ handler: @escaping @MainActor () -> Void) -> AudioObservation {
        let observations = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultOutputDevice,
        ].compactMap { CoreAudioProperty.listen(CoreAudioProperty.systemObject, $0, handler: handler) }
        return AudioObservation { observations.forEach { $0.invalidate() } }
    }

    func observeProcesses(_ handler: @escaping @MainActor () -> Void) -> AudioObservation {
        let observer = ProcessListObserver(handler: handler)
        return AudioObservation { observer.stop() }
    }

    private func hasOutputStreams(_ device: AudioObjectID) -> Bool {
        let streams: [AudioStreamID] = (try? CoreAudioProperty.array(
            device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput
        )) ?? []
        return !streams.isEmpty
    }
}

/// Watches the process list, and each process's "is running output" flag, re-registering
/// per-process listeners whenever the list changes.
@MainActor
private final class ProcessListObserver {
    private let handler: @MainActor () -> Void
    private var listObservation: AudioObservation?
    private var perProcess: [AudioObjectID: AudioObservation] = [:]

    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        listObservation = CoreAudioProperty.listen(
            CoreAudioProperty.systemObject, kAudioHardwarePropertyProcessObjectList
        ) { [weak self] in
            self?.syncProcessListeners()
            self?.handler()
        }
        syncProcessListeners()
    }

    func stop() {
        listObservation?.invalidate()
        listObservation = nil
        perProcess.values.forEach { $0.invalidate() }
        perProcess.removeAll()
    }

    private func syncProcessListeners() {
        let ids: [AudioObjectID] = (try? CoreAudioProperty.array(
            CoreAudioProperty.systemObject, kAudioHardwarePropertyProcessObjectList
        )) ?? []
        let current = Set(ids)
        for (id, observation) in perProcess where !current.contains(id) {
            observation.invalidate()
            perProcess[id] = nil
        }
        for id in current where perProcess[id] == nil {
            perProcess[id] = CoreAudioProperty.listen(id, kAudioProcessPropertyIsRunningOutput) { [weak self] in
                self?.handler()
            }
        }
    }
}
