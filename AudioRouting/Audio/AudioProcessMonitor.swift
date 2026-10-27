import AppKit
import Foundation
import Observation

/// Audio processes grouped under the app they play for (helpers are folded into their parent app).
struct AudioApp: Identifiable, Hashable, Sendable {
    let bundleID: String
    let name: String
    let processes: [AudioProcess]

    var id: String { bundleID }
    var isPlaying: Bool { processes.contains(where: \.isRunningOutput) }
}

/// Publishes the processes that have an audio client, and notifies when they start, stop
/// or start/stop playing.
@MainActor
@Observable
final class AudioProcessMonitor {
    private(set) var processes: [AudioProcess] = []

    /// Called after every refresh that changed the process list.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    @ObservationIgnored private let system: AudioSystem
    @ObservationIgnored private let ownPID: pid_t
    @ObservationIgnored private let appName: (AudioProcess) -> String
    @ObservationIgnored private var observation: AudioObservation?

    init(
        system: AudioSystem,
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        appName: @escaping (AudioProcess) -> String = AudioProcessMonitor.runningApplicationName
    ) {
        self.system = system
        self.ownPID = ownPID
        self.appName = appName
        restartObservation()
    }

    /// (Re)subscribes to Core Audio change notifications and refreshes, e.g. after coreaudiod restarted.
    func restartObservation() {
        observation = nil
        observation = system.observeProcesses { [weak self] in
            self?.refresh()
        }
        refresh()
    }

    /// Apps with a bundle ID, sorted by name. Processes without a bundle ID are left out
    /// because settings are keyed by bundle ID, and so are daemons (not user apps).
    var apps: [AudioApp] {
        Self.groupByApp(processes, appName: appName)
    }

    var playingApps: [AudioApp] {
        apps.filter(\.isPlaying)
    }

    func refresh() {
        let newProcesses = system.audioProcesses().filter { $0.pid != ownPID && $0.appPID != ownPID }
        guard newProcesses != processes else { return }
        processes = newProcesses
        onChange?()
    }

    static func groupByApp(_ processes: [AudioProcess], appName: (AudioProcess) -> String) -> [AudioApp] {
        Dictionary(grouping: processes.filter { !$0.appBundleID.isEmpty && $0.isUserApp }, by: \.appBundleID)
            .map { bundleID, group in
                let sorted = group.sorted { $0.pid < $1.pid }
                // Name the group after the app itself, not after whichever helper sorts first.
                let representative = sorted.first { $0.pid == $0.appPID } ?? sorted[0]
                return AudioApp(bundleID: bundleID, name: appName(representative), processes: sorted)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    nonisolated static func runningApplicationName(_ process: AudioProcess) -> String {
        NSRunningApplication(processIdentifier: process.appPID)?.localizedName ?? process.appBundleID
    }
}
