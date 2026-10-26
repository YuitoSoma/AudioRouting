import AppKit
import CoreAudio
import Foundation

/// Real Core Audio checks run inside the installed app, so they use the app's own
/// "System Audio Recording" permission (test hosts are signed differently and don't share it).
///
///     open -W -a AudioRouting --args --self-test /path/to/report.txt
///
/// Plays a quiet tone with afplay, routes it through ProcessRouter, checks the audio arrives and
/// that every tap and aggregate device is gone afterwards, writes the report and quits.
@MainActor
enum SelfTest {
    static let flag = "--self-test"

    static var requestedReportPath: String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: flag) else { return nil }
        return args.indices.contains(index + 1) ? args[index + 1] : NSTemporaryDirectory() + "AudioRouting-self-test.txt"
    }

    static func runAndQuit(reportPath: String) {
        Task { @MainActor in
            var report = Report()
            await run(&report)
            try? report.text.write(toFile: reportPath, atomically: true, encoding: .utf8)
            exit(report.failed == 0 ? 0 : 1)
        }
    }

    struct Report {
        private(set) var lines: [String] = []
        private(set) var passed = 0
        private(set) var failed = 0
        private(set) var skipped = 0

        mutating func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { passed += 1 } else { failed += 1 }
            lines.append("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : ": \(detail)")")
        }

        mutating func skip(_ name: String, _ reason: String) {
            skipped += 1
            lines.append("SKIP \(name): \(reason)")
        }

        mutating func note(_ text: String) { lines.append("     \(text)") }

        var text: String {
            (lines + ["", "passed: \(passed)  failed: \(failed)  skipped: \(skipped)"]).joined(separator: "\n") + "\n"
        }
    }

    static func run(_ report: inout Report) async {
        let permission = TCCAudioCapturePermission().status
        report.check("permission", permission == .authorized, "\(permission)")

        let system = CoreAudioSystem()
        let devices = system.outputDevices()
        let defaultUID = system.defaultOutputDeviceUID()
        for device in devices {
            report.note("device \(device.uid == defaultUID ? "*" : " ") \(device.name) [\(device.uid)]")
        }
        guard let defaultUID, let defaultDevice = devices.first(where: { $0.uid == defaultUID }) else {
            report.check("default output device", false, "none")
            return
        }
        guard permission == .authorized else {
            report.skip("routing", "no permission")
            return
        }

        let player: Process
        let toneURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("audiorouting-self-test-\(UUID().uuidString).wav")
        do {
            try AudioDiagnostics.toneWAV(seconds: 8).write(to: toneURL)
            player = try AudioDiagnostics.startAfplay(toneURL)
        } catch {
            report.check("start afplay", false, "\(error)")
            return
        }
        defer {
            if player.isRunning { player.terminate() }
            try? FileManager.default.removeItem(at: toneURL)
        }

        let monitor = AudioProcessMonitor(system: system)
        let pid = player.processIdentifier
        let seen = await AudioDiagnostics.waitUntil { monitor.processes.contains { $0.pid == pid && $0.isRunningOutput } }
        report.check("AudioProcessMonitor sees afplay playing", seen)
        guard let process = monitor.processes.first(where: { $0.pid == pid }) else { return }

        var targets = [defaultDevice]
        if let other = devices.first(where: { $0.uid != defaultUID }) { targets.append(other) }

        for device in targets {
            await checkRoute(process: process, device: device, isDefault: device.uid == defaultUID, report: &report)
        }

        let baselineTaps = AudioDiagnostics.tapCount()
        let baselineAggregates = AudioDiagnostics.ownAggregateCount()
        let missing = AudioOutputDevice(objectID: 0, uid: "local.audiorouting.no-such-device", name: "none")
        if let router = try? ProcessRouter(bundleID: "self-test", processObjectIDs: [process.objectID], device: missing) {
            router.stop()
        }
        report.check("missing device leaves nothing behind",
                     AudioDiagnostics.tapCount() == baselineTaps && AudioDiagnostics.ownAggregateCount() == baselineAggregates)
    }

    private static func checkRoute(process: AudioProcess, device: AudioOutputDevice, isDefault: Bool, report: inout Report) async {
        let label = "route to \(device.name)\(isDefault ? " (default)" : "")"
        let baselineTaps = AudioDiagnostics.tapCount()
        let baselineAggregates = AudioDiagnostics.ownAggregateCount()

        let router: ProcessRouter
        do {
            router = try ProcessRouter(bundleID: "self-test", processObjectIDs: [process.objectID], device: device)
        } catch {
            report.check("\(label): start", false, "\(error)")
            return
        }
        report.check("\(label): tap + aggregate created",
                     AudioDiagnostics.tapCount() == baselineTaps + 1 && AudioDiagnostics.ownAggregateCount() == baselineAggregates + 1,
                     "taps \(baselineTaps)->\(AudioDiagnostics.tapCount()), aggregates \(baselineAggregates)->\(AudioDiagnostics.ownAggregateCount())")

        let gotSignal = await AudioDiagnostics.waitUntil(seconds: 3) { router.meter.peak > 0.0005 }
        let running: UInt32 = (try? CoreAudioProperty.value(router.aggregateID, kAudioDevicePropertyDeviceIsRunningSomewhere, initial: 0)) ?? 0
        report.check("\(label): IO running", running == 1)
        report.check("\(label): audio reaches device", gotSignal, String(format: "peak %.4f", router.meter.peak))

        router.stop()
        report.check("\(label): cleaned up",
                     AudioDiagnostics.tapCount() == baselineTaps && AudioDiagnostics.ownAggregateCount() == baselineAggregates)
    }
}

/// Core Audio helpers shared by the self-test and the integration tests.
@MainActor
enum AudioDiagnostics {
    static func tapCount() -> Int {
        let taps: [AudioObjectID] = (try? CoreAudioProperty.array(
            CoreAudioProperty.systemObject, kAudioHardwarePropertyTapList
        )) ?? []
        return taps.count
    }

    /// Aggregate devices this app created (visible only to this process, since they are private).
    static func ownAggregateCount() -> Int {
        let devices: [AudioObjectID] = (try? CoreAudioProperty.array(
            CoreAudioProperty.systemObject, kAudioHardwarePropertyDevices
        )) ?? []
        return devices.filter {
            ((try? CoreAudioProperty.string($0, kAudioDevicePropertyDeviceUID)) ?? "")
                .hasPrefix(AudioRoutingConstants.aggregateUIDPrefix)
        }.count
    }

    static func startAfplay(_ file: URL, volume: String = "0.05") throws -> Process {
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["-v", volume, file.path]
        try player.run()
        return player
    }

    /// Polls, letting the main queue run Core Audio listener callbacks in between.
    static func waitUntil(seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    /// 16-bit mono 440 Hz sine, quiet.
    static func toneWAV(seconds: Int, sampleRate: Int = 44_100) -> Data {
        let frames = seconds * sampleRate
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + frames * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(UInt32(sampleRate)); append(UInt32(sampleRate * 2))
        append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(frames * 2))
        for frame in 0..<frames {
            append(Int16(sin(Double(frame) * 2 * .pi * 440 / Double(sampleRate)) * 3000))
        }
        return data
    }
}
