import AppKit
import SwiftUI

@main
struct AudioRoutingApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("AudioRouting", systemImage: "speaker.wave.2") {
            MenuContentView(router: model.routingManager)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Owns the long-lived monitors and the routing manager for the app's lifetime.
@MainActor
final class AppModel {
    let routingManager: RoutingManager
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

        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [routingManager] _ in
            MainActor.assumeIsolated { routingManager.stopAll() }
        }
    }
}
