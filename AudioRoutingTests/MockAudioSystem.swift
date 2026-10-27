import CoreAudio
@testable import AudioRouting

/// In-memory AudioSystem. Mutate the properties, then call `notifyDevices()` / `notifyProcesses()`.
@MainActor
final class MockAudioSystem: AudioSystem {
    var devices: [AudioOutputDevice] = []
    var defaultUID: String?
    var processes: [AudioProcess] = []

    private var deviceHandlers: [Int: @MainActor () -> Void] = [:]
    private var processHandlers: [Int: @MainActor () -> Void] = [:]
    private var restartHandlers: [Int: @MainActor () -> Void] = [:]
    private var nextToken = 0

    var deviceObserverCount: Int { deviceHandlers.count }
    var processObserverCount: Int { processHandlers.count }

    func outputDevices() -> [AudioOutputDevice] { devices }
    func defaultOutputDeviceUID() -> String? { defaultUID }
    func audioProcesses() -> [AudioProcess] { processes }

    func observeDevices(_ handler: @escaping @MainActor () -> Void) -> AudioObservation {
        let token = takeToken()
        deviceHandlers[token] = handler
        return AudioObservation { [weak self] in
            MainActor.assumeIsolated { self?.deviceHandlers[token] = nil }
        }
    }

    func observeProcesses(_ handler: @escaping @MainActor () -> Void) -> AudioObservation {
        let token = takeToken()
        processHandlers[token] = handler
        return AudioObservation { [weak self] in
            MainActor.assumeIsolated { self?.processHandlers[token] = nil }
        }
    }

    func observeServiceRestart(_ handler: @escaping @MainActor () -> Void) -> AudioObservation {
        let token = takeToken()
        restartHandlers[token] = handler
        return AudioObservation { [weak self] in
            MainActor.assumeIsolated { self?.restartHandlers[token] = nil }
        }
    }

    func notifyServiceRestart() { restartHandlers.values.forEach { $0() } }

    func notifyDevices() { deviceHandlers.values.forEach { $0() } }
    func notifyProcesses() { processHandlers.values.forEach { $0() } }

    private func takeToken() -> Int {
        nextToken += 1
        return nextToken
    }
}

extension AudioOutputDevice {
    static func mock(_ id: AudioObjectID, _ uid: String, _ name: String? = nil) -> AudioOutputDevice {
        AudioOutputDevice(objectID: id, uid: uid, name: name ?? uid)
    }
}

extension AudioProcess {
    static func mock(_ id: AudioObjectID, pid: pid_t, _ bundleID: String, playing: Bool = true) -> AudioProcess {
        AudioProcess(objectID: id, pid: pid, bundleID: bundleID, isRunningOutput: playing)
    }
}

/// Records route starts/stops instead of touching Core Audio.
@MainActor
final class MockRouteFactory: AudioRouteFactory {
    final class Route: ActiveAudioRoute {
        let bundleID: String
        let deviceUID: String
        let processObjectIDs: [AudioObjectID]
        private(set) var isStopped = false

        init(bundleID: String, deviceUID: String, processObjectIDs: [AudioObjectID]) {
            self.bundleID = bundleID
            self.deviceUID = deviceUID
            self.processObjectIDs = processObjectIDs
        }

        func stop() { isStopped = true }
    }

    struct Failure: Error {}

    private(set) var started: [Route] = []
    var failingDeviceUIDs: Set<String> = []

    var running: [Route] { started.filter { !$0.isStopped } }

    func startRoute(bundleID: String, processObjectIDs: [AudioObjectID], device: AudioOutputDevice) throws -> ActiveAudioRoute {
        if failingDeviceUIDs.contains(device.uid) { throw Failure() }
        let route = Route(bundleID: bundleID, deviceUID: device.uid, processObjectIDs: processObjectIDs)
        started.append(route)
        return route
    }
}

@MainActor
final class MockPermission: AudioCapturePermission {
    var status: AudioCapturePermissionStatus
    var grantOnRequest = true
    private(set) var requestCount = 0

    init(_ status: AudioCapturePermissionStatus) {
        self.status = status
    }

    func request(_ completion: @escaping @MainActor (Bool) -> Void) {
        requestCount += 1
        if grantOnRequest { status = .authorized }
        completion(grantOnRequest)
    }
}

final class MemorySettingsStore: SettingsStore {
    var stored = AppRoutingSettings()
    private(set) var saveCount = 0

    func load() -> AppRoutingSettings { stored }
    func save(_ settings: AppRoutingSettings) {
        stored = settings
        saveCount += 1
    }
}

@MainActor
final class MockLoginItemService: LoginItemService {
    struct Failure: Error {}

    var status: LoginItemStatus = .disabled
    var statusAfterRegister: LoginItemStatus = .enabled
    var failNext = false
    private(set) var openedSettings = false

    func register() throws {
        if failNext { failNext = false; throw Failure() }
        status = statusAfterRegister
    }

    func unregister() throws {
        if failNext { failNext = false; throw Failure() }
        status = .disabled
    }

    func openSystemSettings() { openedSettings = true }
}
