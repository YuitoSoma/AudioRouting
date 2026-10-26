import XCTest
@testable import AudioRouting

final class RoutingPlannerTests: XCTestCase {
    private let spotify = AudioApp(bundleID: "com.spotify.client", name: "Spotify",
                                   processes: [.mock(11, pid: 100, "com.spotify.client"), .mock(10, pid: 101, "com.spotify.client")])
    private let zoom = AudioApp(bundleID: "us.zoom.xos", name: "Zoom", processes: [.mock(20, pid: 200, "us.zoom.xos")])

    func testRoutesRunningAppToConnectedNonDefaultDevice() {
        let desired = RoutingPlanner.desiredRoutes(
            settings: AppRoutingSettings(routes: ["com.spotify.client": "headphones"]),
            apps: [spotify, zoom],
            connectedDeviceUIDs: ["speakers", "headphones"],
            defaultOutputUID: "speakers"
        )

        XCTAssertEqual(desired, [
            "com.spotify.client": DesiredRoute(bundleID: "com.spotify.client", deviceUID: "headphones", processObjectIDs: [10, 11]),
        ])
    }

    func testSkipsAppsNotRunning() {
        let desired = RoutingPlanner.desiredRoutes(
            settings: AppRoutingSettings(routes: ["com.spotify.client": "headphones"]),
            apps: [zoom],
            connectedDeviceUIDs: ["speakers", "headphones"],
            defaultOutputUID: "speakers"
        )
        XCTAssertTrue(desired.isEmpty)
    }

    func testSkipsDisconnectedDevice() {
        let desired = RoutingPlanner.desiredRoutes(
            settings: AppRoutingSettings(routes: ["com.spotify.client": "headphones"]),
            apps: [spotify],
            connectedDeviceUIDs: ["speakers"],
            defaultOutputUID: "speakers"
        )
        XCTAssertTrue(desired.isEmpty)
    }

    func testSkipsWhenTargetIsAlreadyDefault() {
        let desired = RoutingPlanner.desiredRoutes(
            settings: AppRoutingSettings(routes: ["com.spotify.client": "speakers"]),
            apps: [spotify],
            connectedDeviceUIDs: ["speakers", "headphones"],
            defaultOutputUID: "speakers"
        )
        XCTAssertTrue(desired.isEmpty)
    }

    func testPlanCreatesMissingAndDestroysStale() {
        let keep = DesiredRoute(bundleID: "a", deviceUID: "d1", processObjectIDs: [1])
        let stale = DesiredRoute(bundleID: "b", deviceUID: "d1", processObjectIDs: [2])
        let new = DesiredRoute(bundleID: "c", deviceUID: "d2", processObjectIDs: [3])

        let plan = RoutingPlanner.plan(desired: ["a": keep, "c": new], active: ["a": keep, "b": stale])

        XCTAssertEqual(plan, RoutingPlan(create: [new], destroy: [stale]))
    }

    func testPlanRebuildsRouteWhenDeviceOrProcessesChange() {
        let old = DesiredRoute(bundleID: "a", deviceUID: "d1", processObjectIDs: [1])
        let otherDevice = DesiredRoute(bundleID: "a", deviceUID: "d2", processObjectIDs: [1])
        let moreProcesses = DesiredRoute(bundleID: "a", deviceUID: "d1", processObjectIDs: [1, 2])

        XCTAssertEqual(RoutingPlanner.plan(desired: ["a": otherDevice], active: ["a": old]),
                       RoutingPlan(create: [otherDevice], destroy: [old]))
        XCTAssertEqual(RoutingPlanner.plan(desired: ["a": moreProcesses], active: ["a": old]),
                       RoutingPlan(create: [moreProcesses], destroy: [old]))
    }

    func testPlanIsEmptyWhenInSync() {
        let route = DesiredRoute(bundleID: "a", deviceUID: "d1", processObjectIDs: [1])
        XCTAssertTrue(RoutingPlanner.plan(desired: ["a": route], active: ["a": route]).isEmpty)
    }
}
