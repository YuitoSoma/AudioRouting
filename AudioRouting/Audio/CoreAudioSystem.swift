import CoreAudio
import Foundation
import os

/// The real AudioSystem, backed by the Core Audio HAL.
@MainActor
final class CoreAudioSystem: AudioSystem {
    private let logger = Logger(subsystem: "local.audiorouting", category: "CoreAudioSystem")
    private let ownerResolver = AppOwnerResolver()

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
        let processes: [AudioProcess] = ids.compactMap { id in
            guard let pid: pid_t = try? CoreAudioProperty.value(id, kAudioProcessPropertyPID, initial: -1),
                  pid > 0
            else { return nil }
            let bundleID = (try? CoreAudioProperty.string(id, kAudioProcessPropertyBundleID)) ?? ""
            let running: UInt32 = (try? CoreAudioProperty.value(id, kAudioProcessPropertyIsRunningOutput, initial: 0)) ?? 0
            let owner = ownerResolver.owner(pid: pid, bundleID: bundleID)
            return AudioProcess(objectID: id, pid: pid, bundleID: bundleID, isRunningOutput: running != 0,
                                appBundleID: owner.bundleID, appPID: owner.pid)
        }
        ownerResolver.retain(pids: Set(processes.map(\.pid)))
        return processes
    }

    func observeDevices(_ handler: @escaping @MainActor () -> Void) -> AudioObservation {
        let observations = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultOutputDevice,
        ].compactMap { CoreAudioProperty.listen(CoreAudioProperty.systemObject, $0, handler: handler) }
        return AudioObservation { observations.forEach { $0.invalidate() } }
    }

    func observeServiceRestart(_ handler: @escaping @MainActor () -> Void) -> AudioObservation {
        CoreAudioProperty.listen(CoreAudioProperty.systemObject, kAudioHardwarePropertyServiceRestarted, handler: handler)
            ?? AudioObservation {}
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

/// Watches the process list, and each process's running state, re-registering per-process
/// listeners whenever the list changes.
@MainActor
private final class ProcessListObserver {
    /// A new process object usually appears before it starts output, so its flags must be watched.
    /// `IsRunningOutput` alone is not enough: on macOS 27 its listener never fires when playback
    /// starts, while `IsRunning` does (observed with afplay).
    private static let perProcessSelectors = [
        kAudioProcessPropertyIsRunning,
        kAudioProcessPropertyIsRunningOutput,
    ]

    private let handler: @MainActor () -> Void
    private var listObservation: AudioObservation?
    private var perProcess: [AudioObjectID: [AudioObservation]] = [:]

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
        perProcess.values.joined().forEach { $0.invalidate() }
        perProcess.removeAll()
    }

    private func syncProcessListeners() {
        let ids: [AudioObjectID] = (try? CoreAudioProperty.array(
            CoreAudioProperty.systemObject, kAudioHardwarePropertyProcessObjectList
        )) ?? []
        let current = Set(ids)
        for (id, observations) in perProcess where !current.contains(id) {
            observations.forEach { $0.discard() }
            perProcess[id] = nil
        }
        for id in current where perProcess[id] == nil {
            perProcess[id] = Self.perProcessSelectors.compactMap { selector in
                CoreAudioProperty.listen(id, selector) { [weak self] in
                    self?.handler()
                }
            }
        }
    }
}
