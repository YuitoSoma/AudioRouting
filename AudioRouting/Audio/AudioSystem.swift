import CoreAudio
import Foundation

/// An output-capable audio device as the rest of the app sees it.
struct AudioOutputDevice: Identifiable, Hashable, Sendable {
    let objectID: AudioObjectID
    let uid: String
    let name: String

    var id: String { uid }
}

/// One Core Audio process object (a process that has an audio client).
struct AudioProcess: Identifiable, Hashable, Sendable {
    let objectID: AudioObjectID
    let pid: pid_t
    /// Empty when Core Audio reports no bundle ID (e.g. command-line tools).
    let bundleID: String
    let isRunningOutput: Bool
    /// The app this process plays audio for. For helpers (Safari's com.apple.WebKit.GPU,
    /// Chrome Helper, ...) this is the parent app; otherwise the process itself.
    let appBundleID: String
    let appPID: pid_t

    init(objectID: AudioObjectID, pid: pid_t, bundleID: String, isRunningOutput: Bool,
         appBundleID: String? = nil, appPID: pid_t? = nil) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.isRunningOutput = isRunningOutput
        self.appBundleID = appBundleID ?? bundleID
        self.appPID = appPID ?? pid
    }

    var id: AudioObjectID { objectID }
}

/// Keeps a Core Audio listener (or a mock's subscription) alive; removes it on deinit.
final class AudioObservation {
    private var cancel: (() -> Void)?

    init(cancel: @escaping () -> Void) {
        self.cancel = cancel
    }

    func invalidate() {
        cancel?()
        cancel = nil
    }

    deinit {
        invalidate()
    }
}

/// Everything the app needs from Core Audio, behind a protocol so logic can be tested with a mock.
/// Change handlers are called on the main queue.
@MainActor
protocol AudioSystem: AnyObject {
    func outputDevices() -> [AudioOutputDevice]
    func defaultOutputDeviceUID() -> String?
    func audioProcesses() -> [AudioProcess]

    /// Device added/removed or the system default output changed.
    func observeDevices(_ handler: @escaping @MainActor () -> Void) -> AudioObservation
    /// Process list changed or a process started/stopped playing.
    func observeProcesses(_ handler: @escaping @MainActor () -> Void) -> AudioObservation
}

enum AudioRoutingConstants {
    /// UID prefix of the aggregate devices this app creates; they are hidden from device lists.
    static let aggregateUIDPrefix = "local.audiorouting.aggregate."
}
