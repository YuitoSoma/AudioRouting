import AppKit
import SwiftUI

@main
struct AudioRoutingApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("AudioRouting", systemImage: "speaker.wave.2") {
            MenuContentView(router: model.routingManager, loginItem: model.loginItem)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Owns the long-lived monitors and the routing manager for the app's lifetime.
@MainActor
final class AppModel {
    let routingManager: RoutingManager
    let loginItem = LoginItemController(service: MainAppLoginItemService())
    private var restartObservation: AudioObservation?
    private var permissionTimer: Timer?
    private var terminateObserver: NSObjectProtocol?

    init(system: AudioSystem = CoreAudioSystem()) {
        routingManager = RoutingManager(
            deviceMonitor: AudioDeviceMonitor(system: system),
            processMonitor: AudioProcessMonitor(system: system),
            factory: ProcessRouterFactory(),
            permission: TCCAudioCapturePermission(),
            store: UserDefaultsSettingsStore()
        )
        if let reportPath = SelfTest.requestedReportPath {
            SelfTest.runAndQuit(reportPath: reportPath)
            return
        }
        routingManager.reconcile()

        restartObservation = system.observeServiceRestart { [routingManager] in
            routingManager.audioServiceRestarted()
        }
        // There is no notification for the permission being granted or revoked in System Settings.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [routingManager] _ in
            MainActor.assumeIsolated { routingManager.refreshPermission() }
        }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [routingManager] _ in
            MainActor.assumeIsolated { routingManager.stopAll() }
        }
    }
}
