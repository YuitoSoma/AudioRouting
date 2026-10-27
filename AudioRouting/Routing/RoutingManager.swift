import CoreAudio
import Foundation
import Observation
import os

/// A running route; stopping it must release every Core Audio object it created.
@MainActor
protocol ActiveAudioRoute: AnyObject {
    func stop()
}

/// Starts a route for a set of process objects to one device. The real one is ProcessRouter.
@MainActor
protocol AudioRouteFactory {
    func startRoute(bundleID: String, processObjectIDs: [AudioObjectID], device: AudioOutputDevice) throws -> ActiveAudioRoute
}

/// What the menu shows for one app.
enum AppRouteStatus: Equatable, Sendable {
    case systemDefault
    case routed(deviceUID: String)
    /// The saved device is not connected; the app plays through the default output until it returns.
    case deviceMissing(deviceUID: String)
    case failed(deviceUID: String, message: String)
    case needsPermission(deviceUID: String)
}

/// Holds the app -> device settings and keeps the running ProcessRouters in line with them.
@MainActor
@Observable
final class RoutingManager {
    private(set) var settings: AppRoutingSettings
    private(set) var permissionStatus: AudioCapturePermissionStatus
    /// Routes currently running, keyed by bundle ID.
    private(set) var activeRoutes: [String: DesiredRoute] = [:]
    /// Routes that failed to start; not retried until the desired route changes.
    private(set) var failedRoutes: [String: (route: DesiredRoute, message: String)] = [:]

    @ObservationIgnored let deviceMonitor: AudioDeviceMonitor
    @ObservationIgnored let processMonitor: AudioProcessMonitor
    @ObservationIgnored private let factory: AudioRouteFactory
    @ObservationIgnored private let permission: AudioCapturePermission
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private var routers: [String: ActiveAudioRoute] = [:]
    @ObservationIgnored private let logger = Logger(subsystem: "local.audiorouting", category: "RoutingManager")

    init(
        deviceMonitor: AudioDeviceMonitor,
        processMonitor: AudioProcessMonitor,
        factory: AudioRouteFactory,
        permission: AudioCapturePermission,
        store: SettingsStore
    ) {
        self.deviceMonitor = deviceMonitor
        self.processMonitor = processMonitor
        self.factory = factory
        self.permission = permission
        self.store = store
        settings = store.load()
        permissionStatus = permission.status

        deviceMonitor.onChange = { [weak self] in self?.devicesChanged() }
        processMonitor.onChange = { [weak self] in self?.reconcile() }
    }

    // MARK: Settings

    func selectedDeviceUID(for bundleID: String) -> String? {
        settings.routes[bundleID]
    }

    /// Sends the app to `deviceUID`, or back to the default output when nil.
    func setOutput(app bundleID: String, deviceUID: String?) {
        guard let deviceUID else {
            revertToDefault(app: bundleID)
            return
        }
        settings.routes[bundleID] = deviceUID
        store.save(settings)
        // Choosing an output again is how the user retries a route that failed to start.
        failedRoutes[bundleID] = nil
        if permission.status == .unknown {
            requestPermission()
        }
        reconcile()
    }

    /// Removes the app's routing so it plays through the system default output again.
    func revertToDefault(app bundleID: String) {
        settings.routes[bundleID] = nil
        store.save(settings)
        reconcile()
    }

    /// Re-reads the permission and reconciles if it changed (granted or revoked in System Settings).
    func refreshPermission() {
        if permission.status != permissionStatus {
            reconcile()
        }
    }

    func requestPermission() {
        permission.request { [weak self] _ in
            self?.reconcile()
        }
    }

    // MARK: Reconciling

    /// Called when devices are added or removed or the default output changes. Apps whose device
    /// went away fall back to the default output (their tap is destroyed); their setting is kept,
    /// so they are routed again when the device comes back.
    func devicesChanged() {
        reconcile()
    }

    /// Computes the routes that should exist and creates/destroys only the difference.
    func reconcile() {
        permissionStatus = permission.status
        let desired: [String: DesiredRoute]
        if permissionStatus == .authorized {
            desired = RoutingPlanner.desiredRoutes(
                settings: settings,
                apps: processMonitor.apps,
                connectedDeviceUIDs: deviceMonitor.deviceUIDs,
                defaultOutputUID: deviceMonitor.defaultOutputUID
            )
        } else {
            desired = [:]
        }

        failedRoutes = failedRoutes.filter { desired[$0.key] == $0.value.route }
        let plan = RoutingPlanner.plan(desired: desired, active: activeRoutes)

        for route in plan.destroy {
            stopRouter(bundleID: route.bundleID)
        }
        for route in plan.create where failedRoutes[route.bundleID] == nil {
            startRouter(route)
        }
    }

    /// coreaudiod restarted: every tap, aggregate and process object ID is gone. Drop the stale
    /// routers and failures and build everything again from the settings.
    func audioServiceRestarted() {
        logger.notice("audio service restarted; rebuilding routes")
        stopAll()
        failedRoutes = [:]
        deviceMonitor.restartObservation()
        processMonitor.restartObservation()
        reconcile()
    }

    /// Tears down every route (on quit). Settings are kept.
    func stopAll() {
        for bundleID in Array(routers.keys) {
            stopRouter(bundleID: bundleID)
        }
    }

    func status(for bundleID: String) -> AppRouteStatus {
        guard let deviceUID = settings.routes[bundleID] else { return .systemDefault }
        if let route = activeRoutes[bundleID], route.deviceUID == deviceUID {
            return .routed(deviceUID: deviceUID)
        }
        if let failure = failedRoutes[bundleID] {
            return .failed(deviceUID: deviceUID, message: failure.message)
        }
        if !deviceMonitor.deviceUIDs.contains(deviceUID) {
            return .deviceMissing(deviceUID: deviceUID)
        }
        if permissionStatus != .authorized {
            return .needsPermission(deviceUID: deviceUID)
        }
        // Running app whose saved device is the current default, or app not running.
        return .routed(deviceUID: deviceUID)
    }

    private func startRouter(_ route: DesiredRoute) {
        guard let device = deviceMonitor.device(uid: route.deviceUID) else { return }
        do {
            routers[route.bundleID] = try factory.startRoute(
                bundleID: route.bundleID, processObjectIDs: route.processObjectIDs, device: device
            )
            activeRoutes[route.bundleID] = route
        } catch {
            logger.error("start route \(route.bundleID) -> \(route.deviceUID): \(error)")
            failedRoutes[route.bundleID] = (route, String(describing: error))
        }
    }

    private func stopRouter(bundleID: String) {
        routers.removeValue(forKey: bundleID)?.stop()
        activeRoutes[bundleID] = nil
    }
}
