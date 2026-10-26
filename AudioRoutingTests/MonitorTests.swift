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

        let apps = AudioProcessMonitor.groupByBundleID(processes, appName: { $0.bundleID })

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
}
