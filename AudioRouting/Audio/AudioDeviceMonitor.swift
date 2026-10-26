import Foundation
import Observation

/// Publishes the connected output devices and the system default output, and notifies on changes.
@MainActor
@Observable
final class AudioDeviceMonitor {
    private(set) var devices: [AudioOutputDevice] = []
    private(set) var defaultOutputUID: String?

    /// Called after every refresh that changed the device set or the default output.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    @ObservationIgnored private let system: AudioSystem
    @ObservationIgnored private var observation: AudioObservation?

    init(system: AudioSystem) {
        self.system = system
        refresh()
        observation = system.observeDevices { [weak self] in
            self?.refresh()
        }
    }

    var deviceUIDs: Set<String> { Set(devices.map(\.uid)) }

    func device(uid: String) -> AudioOutputDevice? {
        devices.first { $0.uid == uid }
    }

    func refresh() {
        let newDevices = system.outputDevices()
        let newDefault = system.defaultOutputDeviceUID()
        guard newDevices != devices || newDefault != defaultOutputUID else { return }
        devices = newDevices
        defaultOutputUID = newDefault
        onChange?()
    }
}
