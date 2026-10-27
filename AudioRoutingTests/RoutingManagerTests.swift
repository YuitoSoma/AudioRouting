import XCTest
@testable import AudioRouting

@MainActor
final class RoutingManagerTests: XCTestCase {
    private var system: MockAudioSystem!
    private var factory: MockRouteFactory!
    private var permission: MockPermission!
    private var store: MemorySettingsStore!

    override func setUp() async throws {
        system = MockAudioSystem()
        system.devices = [.mock(1, "speakers"), .mock(2, "headphones"), .mock(3, "hdmi")]
        system.defaultUID = "speakers"
        system.processes = [
            .mock(10, pid: 100, "com.spotify.client"),
            .mock(20, pid: 200, "us.zoom.xos"),
        ]
        factory = MockRouteFactory()
        permission = MockPermission(.authorized)
        store = MemorySettingsStore()
    }

    private func makeManager() -> RoutingManager {
        let manager = RoutingManager(
            deviceMonitor: AudioDeviceMonitor(system: system),
            processMonitor: AudioProcessMonitor(system: system, ownPID: 999, appName: { $0.bundleID }),
            factory: factory,
            permission: permission,
            store: store
        )
        manager.reconcile()
        return manager
    }

    // MARK: Settings

    func testSetOutputStartsRouteAndSaves() {
        let manager = makeManager()

        manager.setOutput(app: "com.spotify.client", deviceUID: "headphones")

        XCTAssertEqual(factory.running.map(\.deviceUID), ["headphones"])
        XCTAssertEqual(factory.running.first?.processObjectIDs, [10])
        XCTAssertEqual(store.stored.routes, ["com.spotify.client": "headphones"])
        XCTAssertEqual(manager.status(for: "com.spotify.client"), .routed(deviceUID: "headphones"))
        XCTAssertEqual(manager.status(for: "us.zoom.xos"), .systemDefault)
    }

    func testRestoresSavedRoutesOnLaunch() {
        store.stored = AppRoutingSettings(routes: ["com.spotify.client": "headphones"])

        _ = makeManager()

        XCTAssertEqual(factory.running.map(\.bundleID), ["com.spotify.client"])
    }

    func testReconcileIsIdempotent() {
        let manager = makeManager()
        manager.setOutput(app: "com.spotify.client", deviceUID: "headphones")

        manager.reconcile()
        manager.reconcile()

        XCTAssertEqual(factory.started.count, 1)
    }

    // MARK: Switching devices

    func testSwitchingDeviceDestroysOldRouteAndCreatesNew() {
        let manager = makeManager()
        manager.setOutput(app: "com.spotify.client", deviceUID: "headphones")
        let old = factory.started[0]

        manager.setOutput(app: "com.spotify.client", deviceUID: "hdmi")

        XCTAssertTrue(old.isStopped)
        XCTAssertEqual(factory.running.map(\.deviceUID), ["hdmi"])
    }

    func testRevertToDefaultDestroysRouteAndForgetsSetting() {
        let manager = makeManager()
        manager.setOutput(app: "com.spotify.client", deviceUID: "headphones")

        manager.revertToDefault(app: "com.spotify.client")

        XCTAssertTrue(factory.running.isEmpty)
        XCTAssertEqual(store.stored.routes, [:])
        XCTAssertEqual(manager.status(for: "com.spotify.client"), .systemDefault)
    }

    func testSetOutputNilRevertsToDefault() {
        let manager = makeManager()
        manager.setOutput(app: "com.spotify.client", deviceUID: "headphones")

        manager.setOutput(app: "com.spotify.client", deviceUID: nil)

        XCTAssertTrue(factory.running.isEmpty)
        XCTAssertNil(manager.selectedDeviceUID(for: "com.spotify.client"))
    }

    func testRoutingToCurrentDefaultNeedsNoTap() {
        let manager = makeManager()

        manager.setOutput(app: "com.spotify.client", deviceUID: "speakers")

        XCTAssertTrue(factory.started.isEmpty)
        XCTAssertEqual(manager.status(for: "com.spotify.client"), .routed(deviceUID: "speakers"))
    }

    func testDefaultOutputChangeAddsOrRemovesTap() {
        let manager = makeManager()
        manager.setOutput(app: "com.spotify.client", deviceUID: "speakers")

        system.defaultUID = "headphones"
        system.notifyDevices()
        XCTAssertEqual(factory.running.map(\.deviceUID), ["speakers"])

        system.defaultUID = "speakers"
        system.notifyDevices()
        XCTAssertTrue(factory.running.isEmpty)
        _ = manager
    }

    // MARK: Device disconnect / reconnect

    func testDisconnectFallsBackToDefaultAndReconnectRestores() {
        let manager = makeManager()
        manager.setOutput(app: "com.spotify.client", deviceUID: "headphones")
        let first = factory.started[0]

        system.devices.removeAll { $0.uid == "headphones" }
        system.notifyDevices()

        XCTAssertTrue(first.isStopped)
        XCTAssertTrue(factory.running.isEmpty)
        XCTAssertEqual(manager.status(for: "com.spotify.client"), .deviceMissing(deviceUID: "headphones"))
        XCTAssertEqual(store.stored.routes, ["com.spotify.client": "headphones"], "setting is kept while unplugged")

        system.devices.append(.mock(4, "headphones"))
        system.notifyDevices()

        XCTAssertEqual(factory.running.map(\.deviceUID), ["headphones"])
        XCTAssertEqual(manager.status(for: "com.spotify.client"), .routed(deviceUID: "headphones"))
    }

    func testDisconnectOnlyAffectsAppsOnThatDevice() {
        let manager = makeManager()
        manager.setOutput(app: "com.spotify.client", deviceUID: "headphones")
        manager.setOutput(app: "us.zoom.xos", deviceUID: "hdmi")

        system.devices.removeAll { $0.uid == "headphones" }
        system.notifyDevices()

        XCTAssertEqual(factory.running.map(\.bundleID), ["us.zoom.xos"])
    }

    // MARK: App quit / launch

    func testAppQuitDestroysRouteAndRelaunchRestoresIt() {
        let manager = makeManager()
        manager.setOutput(app: "com.spotify.client", deviceUID: "headphones")

        system.processes.removeAll { $0.bundleID == "com.spotify.client" }
        system.notifyProcesses()
        XCTAssertTrue(factory.running.isEmpty)

        system.processes.append(.mock(30, pid: 300, "com.spotify.client"))
        system.notifyProcesses()
        XCTAssertEqual(factory.running.map(\.processObjectIDs), [[30]])
        _ = manager
    }

    func testNewHelperProcessRebuildsTap() {
        let manager = makeManager()
        manager.setOutput(app: "com.spotify.client", deviceUID: "headphones")

        system.processes.append(.mock(11, pid: 101, "com.spotify.client"))
        system.notifyProcesses()

        XCTAssertTrue(factory.started[0].isStopped)
        XCTAssertEqual(factory.running.map(\.processObjectIDs), [[10, 11]])
        _ = manager
    }

    func testStopAllStopsEverythingButKeepsSettings() {
        let manager = makeManager()
        manager.setOutput(app: "com.spotify.client", deviceUID: "headphones")
        manager.setOutput(app: "us.zoom.xos", deviceUID: "hdmi")

        manager.stopAll()

        XCTAssertTrue(factory.running.isEmpty)
        XCTAssertEqual(store.stored.routes.count, 2)
    }

    // MARK: Failures

    func testFailedStartIsReportedAndNotRetriedInALoop() {
        factory.failingDeviceUIDs = ["headphones"]
        let manager = makeManager()

        manager.setOutput(app: "com.spotify.client", deviceUID: "headphones")
        manager.reconcile()

        XCTAssertTrue(factory.started.isEmpty)
        guard case .failed(deviceUID: "headphones", _) = manager.status(for: "com.spotify.client") else {
            return XCTFail("expected failed, got \(manager.status(for: "com.spotify.client"))")
        }

        factory.failingDeviceUIDs = []
        manager.setOutput(app: "com.spotify.client", deviceUID: "hdmi")
        XCTAssertEqual(factory.running.map(\.deviceUID), ["hdmi"])
    }

    // MARK: Permission

    func testNoPermissionCreatesNoRoutesAndReportsIt() {
        permission = MockPermission(.denied)
        let manager = makeManager()

        manager.setOutput(app: "com.spotify.client", deviceUID: "headphones")

        XCTAssertTrue(factory.started.isEmpty)
        XCTAssertEqual(manager.permissionStatus, .denied)
        XCTAssertEqual(manager.status(for: "com.spotify.client"), .needsPermission(deviceUID: "headphones"))
        XCTAssertEqual(permission.requestCount, 0, "a denied permission is not re-requested; the UI points to System Settings")
    }

    func testUnknownPermissionIsRequestedThenRoutes() {
        permission = MockPermission(.unknown)
        let manager = makeManager()
        XCTAssertTrue(factory.started.isEmpty)

        manager.setOutput(app: "com.spotify.client", deviceUID: "headphones")

        XCTAssertEqual(permission.requestCount, 1)
        XCTAssertEqual(manager.permissionStatus, .authorized)
        XCTAssertEqual(factory.running.map(\.deviceUID), ["headphones"])
    }

    func testRefusedRequestLeavesNoRoutes() {
        permission = MockPermission(.unknown)
        permission.grantOnRequest = false
        let manager = makeManager()

        manager.setOutput(app: "com.spotify.client", deviceUID: "headphones")

        XCTAssertTrue(factory.started.isEmpty)
        XCTAssertEqual(manager.status(for: "com.spotify.client"), .needsPermission(deviceUID: "headphones"))
    }

    func testRevokedPermissionTearsDownRoutes() {
        let manager = makeManager()
        manager.setOutput(app: "com.spotify.client", deviceUID: "headphones")

        permission.status = .denied
        manager.reconcile()

        XCTAssertTrue(factory.running.isEmpty)
        XCTAssertEqual(manager.permissionStatus, .denied)
    }

    // MARK: Retry, permission changes, service restart

    func testChoosingOutputAgainRetriesAFailedRoute() {
        factory.failingDeviceUIDs = ["headphones"]
        let manager = makeManager()
        manager.setOutput(app: "com.spotify.client", deviceUID: "headphones")
        XCTAssertTrue(factory.started.isEmpty)

        factory.failingDeviceUIDs = []
        manager.setOutput(app: "com.spotify.client", deviceUID: "headphones")

        XCTAssertEqual(factory.running.map(\.deviceUID), ["headphones"])
        XCTAssertEqual(manager.status(for: "com.spotify.client"), .routed(deviceUID: "headphones"))
    }

    func testPermissionGrantedLaterIsPickedUpByRefresh() {
        permission = MockPermission(.denied)
        store.stored = AppRoutingSettings(routes: ["com.spotify.client": "headphones"])
        let manager = makeManager()
        XCTAssertTrue(factory.started.isEmpty)

        manager.refreshPermission()
        XCTAssertTrue(factory.started.isEmpty, "nothing changed yet")

        permission.status = .authorized
        manager.refreshPermission()

        XCTAssertEqual(manager.permissionStatus, .authorized)
        XCTAssertEqual(factory.running.map(\.deviceUID), ["headphones"])
    }

    func testServiceRestartRebuildsRoutesEvenWithSameObjectIDs() {
        let manager = makeManager()
        manager.setOutput(app: "com.spotify.client", deviceUID: "headphones")
        let before = factory.started[0]

        manager.audioServiceRestarted()

        XCTAssertTrue(before.isStopped)
        XCTAssertEqual(factory.running.count, 1)
        XCTAssertFalse(factory.running[0] === before)
        XCTAssertEqual(system.deviceObserverCount, 1, "monitors re-subscribed without piling up observers")
        XCTAssertEqual(system.processObserverCount, 1)
    }

    func testServiceRestartClearsFailures() {
        factory.failingDeviceUIDs = ["headphones"]
        let manager = makeManager()
        manager.setOutput(app: "com.spotify.client", deviceUID: "headphones")

        factory.failingDeviceUIDs = []
        manager.audioServiceRestarted()

        XCTAssertEqual(factory.running.map(\.deviceUID), ["headphones"])
    }
}
