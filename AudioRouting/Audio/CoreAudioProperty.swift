import CoreAudio
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let operation: String

    var description: String { "\(operation) failed (OSStatus \(status))" }
}

/// Thin typed wrappers over AudioObjectGetPropertyData and friends.
enum CoreAudioProperty {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func value<T: BitwiseCopyable>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        initial: T
    ) throws -> T {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        guard status == noErr else { throw CoreAudioError(status: status, operation: "get \(fourCC(selector))") }
        return value
    }

    static func array<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> [T] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size)
        guard status == noErr else { throw CoreAudioError(status: status, operation: "size \(fourCC(selector))") }
        let capacity = Int(size) / MemoryLayout<T>.stride
        guard capacity > 0 else { return [] }
        let result = [T](unsafeUninitializedCapacity: capacity) { buffer, initialized in
            var readSize = size
            status = AudioObjectGetPropertyData(object, &addr, 0, nil, &readSize, buffer.baseAddress!)
            initialized = status == noErr ? Int(readSize) / MemoryLayout<T>.stride : 0
        }
        guard status == noErr else { throw CoreAudioError(status: status, operation: "get \(fourCC(selector))") }
        return result
    }

    static func string(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> String {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var ref: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ref)
        guard status == noErr else { throw CoreAudioError(status: status, operation: "get \(fourCC(selector))") }
        return ref?.takeRetainedValue() as String? ?? ""
    }

    /// Registers a listener block on the main queue. Returns nil if Core Audio refuses it.
    static func listen(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        handler: @escaping @MainActor () -> Void
    ) -> AudioObservation? {
        var addr = address(selector, scope: scope)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { handler() }
        }
        let status = AudioObjectAddPropertyListenerBlock(object, &addr, DispatchQueue.main, block)
        guard status == noErr else { return nil }
        return AudioObservation {
            var addr = addr
            AudioObjectRemovePropertyListenerBlock(object, &addr, DispatchQueue.main, block)
        }
    }

    static func fourCC(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return String(decoding: bytes, as: UTF8.self)
        }
        return String(value)
    }
}
