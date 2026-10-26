import Foundation

enum AudioCapturePermissionStatus: Equatable, Sendable {
    case authorized
    case denied
    /// Not asked yet, or the status could not be read.
    case unknown
}

@MainActor
protocol AudioCapturePermission: AnyObject {
    var status: AudioCapturePermissionStatus { get }
    func request(_ completion: @escaping @MainActor (Bool) -> Void)
}

/// Reads and requests the "System Audio Recording" permission.
///
/// macOS has no public API for this, so this uses the TCC SPI (`TCCAccessPreflight` /
/// `TCCAccessRequest`), as open-source tools such as AudioCap do. If the SPI is missing the
/// status is `.unknown` and routing is not attempted until the user grants access.
@MainActor
final class TCCAudioCapturePermission: AudioCapturePermission {
    private typealias PreflightFunc = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunc = @convention(c) (CFString, CFDictionary?, @convention(block) @escaping (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private let preflight: PreflightFunc?
    private let requestAccess: RequestFunc?

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
        preflight = dlsym(handle, "TCCAccessPreflight").map { unsafeBitCast($0, to: PreflightFunc.self) }
        requestAccess = dlsym(handle, "TCCAccessRequest").map { unsafeBitCast($0, to: RequestFunc.self) }
    }

    var status: AudioCapturePermissionStatus {
        switch preflight?(Self.service, nil) {
        case 0: .authorized
        case 1: .denied
        default: .unknown
        }
    }

    func request(_ completion: @escaping @MainActor (Bool) -> Void) {
        guard let requestAccess else {
            completion(false)
            return
        }
        requestAccess(Self.service, nil) { granted in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(granted) }
            }
        }
    }
}
