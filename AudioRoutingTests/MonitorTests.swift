import XCTest
@testable import AudioRouting

@MainActor
final class AudioDeviceMonitorTests: XCTestCase {
    func testLoadsDevicesAndDefaultOnInit() {
        let system = MockAudioSystem()
        system.devices = [.mock(1, "speakers"), .mock(2, "headphones")]
        system.defaultUID = "speakers"

        let monitor = AudioDeviceMonitor(system: system)

        XCTAssertEqual(monitor.devices.map(\.uid), ["speakers", "headphones"])
        XCTAssertEqual(monitor.defaultOutputUID, "speakers")
        XCTAssertEqual(monitor.device(uid: "headphones")?.objectID, 2)
    }

    func testNotifiesOnDeviceAddedRemovedAndDefaultChanged() {
        let system = MockAudioSystem()
        system.devices = [.mock(1, "speakers")]
        system.defaultUID = "speakers"
        let monitor = AudioDeviceMonitor(system: system)
        var changes = 0
        monitor.onChange = { changes += 1 }

        system.devices.append(.mock(2, "headphones"))
        system.notifyDevices()
        XCTAssertEqual(monitor.deviceUIDs, ["speakers", "headphones"])

        system.defaultUID = "headphones"
        system.notifyDevices()
        XCTAssertEqual(monitor.defaultOutputUID, "headphones")

        system.devices.removeFirst()
        system.notifyDevices()
        XCTAssertEqual(monitor.deviceUIDs, ["headphones"])

        XCTAssertEqual(changes, 3)
    }

    func testDoesNotNotifyWhenNothingChanged() {
        let system = MockAudioSystem()
        system.devices = [.mock(1, "speakers")]
        let monitor = AudioDeviceMonitor(system: system)
        var changes = 0
        monitor.onChange = { changes += 1 }

        system.notifyDevices()

        XCTAssertEqual(changes, 0)
    }

    func testStopsObservingWhenReleased() {
        let system = MockAudioSystem()
        var monitor: AudioDeviceMonitor? = AudioDeviceMonitor(system: system)
        XCTAssertEqual(system.deviceObserverCount, 1)
        monitor = nil
        XCTAssertNil(monitor)
        XCTAssertEqual(system.deviceObserverCount, 0)
    }
}

@MainActor
final class AudioProcessMonitorTests: XCTestCase {
    private func makeMonitor(_ system: MockAudioSystem, ownPID: pid_t = 999) -> AudioProcessMonitor {
        AudioProcessMonitor(system: system, ownPID: ownPID, appName: { $0.bundleID })
    }

    func testExcludesOwnProcess() {
        let system = MockAudioSystem()
        system.processes = [.mock(10, pid: 999, "local.audiorouting.AudioRouting"), .mock(11, pid: 100, "com.spotify.client")]

        let monitor = makeMonitor(system)

        XCTAssertEqual(monitor.processes.map(\.pid), [100])
    }

    func testPlayingAppsOnlyIncludesAppsRunningOutput() {
        let system = MockAudioSystem()
        system.processes = [
            .mock(10, pid: 100, "com.spotify.client", playing: true),
            .mock(11, pid: 101, "us.zoom.xos", playing: false),
        ]

        let monitor = makeMonitor(system)

        XCTAssertEqual(monitor.apps.map(\.bundleID), ["com.spotify.client", "us.zoom.xos"])
        XCTAssertEqual(monitor.playingApps.map(\.bundleID), ["com.spotify.client"])
    }

    func testGroupsProcessesWithSameBundleIDAndDropsEmptyBundleID() {
        let processes: [AudioProcess] = [
            .mock(12, pid: 201, "com.example.app", playing: false),
            .mock(10, pid: 200, "com.example.app", playing: true),
            .mock(11, pid: 300, "", playing: true),
        ]

        let apps = AudioProcessMonitor.groupByApp(processes, appName: { $0.bundleID })

        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].processes.map(\.pid), [200, 201])
        XCTAssertTrue(apps[0].isPlaying)
    }

    func testNotifiesOnLaunchQuitAndPlayStateChange() {
        let system = MockAudioSystem()
        let monitor = makeMonitor(system)
        var changes = 0
        monitor.onChange = { changes += 1 }

        system.processes = [.mock(10, pid: 100, "com.spotify.client", playing: false)]
        system.notifyProcesses()
        XCTAssertTrue(monitor.playingApps.isEmpty)

        system.processes = [.mock(10, pid: 100, "com.spotify.client", playing: true)]
        system.notifyProcesses()
        XCTAssertEqual(monitor.playingApps.map(\.bundleID), ["com.spotify.client"])

        system.processes = []
        system.notifyProcesses()
        XCTAssertTrue(monitor.apps.isEmpty)

        XCTAssertEqual(changes, 3)
    }

    func testHelpersAreGroupedUnderTheirParentApp() {
        let processes: [AudioProcess] = [
            AudioProcess(objectID: 10, pid: 300, bundleID: "com.apple.WebKit.GPU", isRunningOutput: true,
                         appBundleID: "com.apple.Safari", appPID: 200),
            AudioProcess(objectID: 11, pid: 200, bundleID: "com.apple.Safari", isRunningOutput: false),
            AudioProcess(objectID: 12, pid: 400, bundleID: "com.google.Chrome.helper", isRunningOutput: true,
                         appBundleID: "com.google.Chrome", appPID: 401),
        ]

        let apps = AudioProcessMonitor.groupByApp(processes, appName: { "name of \($0.pid)" })

        XCTAssertEqual(apps.map(\.bundleID), ["com.apple.Safari", "com.google.Chrome"], "sorted by name")
        let safari = apps.first { $0.bundleID == "com.apple.Safari" }
        XCTAssertEqual(safari?.processes.map(\.objectID), [11, 10])
        XCTAssertEqual(safari?.name, "name of 200", "named after the app, not the helper")
        XCTAssertEqual(safari?.isPlaying, true, "playing because its helper is")
        let chrome = apps.first { $0.bundleID == "com.google.Chrome" }
        XCTAssertEqual(chrome?.name, "name of 400", "falls back to a helper when the app itself has no audio client")
    }

    func testLeavesOutDaemons() {
        let processes: [AudioProcess] = [
            AudioProcess(objectID: 10, pid: 300, bundleID: "com.apple.assistantd", isRunningOutput: true, isUserApp: false),
            .mock(11, pid: 301, "com.spotify.client"),
        ]

        XCTAssertEqual(AudioProcessMonitor.groupByApp(processes, appName: { $0.bundleID }).map(\.bundleID), ["com.spotify.client"])
    }

    func testExcludesHelpersOfOwnApp() {
        let system = MockAudioSystem()
        system.processes = [AudioProcess(objectID: 10, pid: 500, bundleID: "x.helper", isRunningOutput: true,
                                         appBundleID: "local.audiorouting.AudioRouting", appPID: 999)]

        XCTAssertTrue(makeMonitor(system).processes.isEmpty)
    }
}

final class AppOwnerResolverTests: XCTestCase {
    func testOutermostAppBundlePath() {
        XCTAssertEqual(
            AppOwnerResolver.outermostAppBundlePath(containing:
                "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"),
            "/Applications/Google Chrome.app")
        XCTAssertEqual(AppOwnerResolver.outermostAppBundlePath(containing: "/Applications/Music.app/Contents/MacOS/Music"),
                       "/Applications/Music.app")
        XCTAssertNil(AppOwnerResolver.outermostAppBundlePath(containing:
            "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"))
        XCTAssertNil(AppOwnerResolver.outermostAppBundlePath(containing: "/usr/bin/afplay"))
    }

    func testUserAppPolicy() {
        XCTAssertTrue(AppOwnerResolver.isUserApp(policy: .regular, bundlePath: "/System/Applications/Music.app"))
        XCTAssertTrue(AppOwnerResolver.isUserApp(policy: .accessory, bundlePath: "/Applications/MenuPlayer.app"))
        XCTAssertFalse(AppOwnerResolver.isUserApp(policy: .accessory, bundlePath: "/System/Library/CoreServices/ControlCenter.app"))
        XCTAssertFalse(AppOwnerResolver.isUserApp(policy: .accessory, bundlePath: nil))
        XCTAssertFalse(AppOwnerResolver.isUserApp(policy: .prohibited, bundlePath: "/Applications/Daemon.app"))
    }

    @MainActor
    func testResolvesAnAppToItselfAndSkipsToolsWithoutBundleID() {
        let resolver = AppOwnerResolver()
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownID = Bundle.main.bundleIdentifier ?? ""

        XCTAssertEqual(resolver.owner(pid: pid, bundleID: ownID), .init(bundleID: ownID, pid: pid, isUserApp: true))
        XCTAssertEqual(resolver.owner(pid: 12345, bundleID: ""), .init(bundleID: "", pid: 12345))
    }
}
