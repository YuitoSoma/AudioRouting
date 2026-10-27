import AppKit
import Darwin
import Foundation

/// Finds the app a helper process plays audio for, so e.g. Safari's com.apple.WebKit.GPU and
/// Chrome Helper are routed together with Safari and Chrome.
///
/// Tries, in order:
/// 1. the outermost `.app` bundle containing the executable: the app itself when the process is
///    an app's main executable, or the parent app for helpers inside it (`Chrome.app/Contents/...`);
/// 2. for helpers outside any `.app` (Safari's WebKit GPU process lives in WebKit.framework), the
///    "responsible" process macOS attributes them to (`responsibility_get_pid_responsible_for_pid`,
///    an SPI also used by Activity Monitor), if that is a regular app;
/// 3. the process itself.
///
/// Only processes that have a bundle ID are resolved; command-line tools (no bundle ID) stay
/// unrouted rather than being folded into the terminal that launched them.
@MainActor
final class AppOwnerResolver {
    struct Owner: Equatable, Sendable {
        let bundleID: String
        let pid: pid_t
        /// The owner is an app a user would route: a regular (Dock) app, or a menu bar app that is
        /// not part of macOS. Daemons and system agents (Control Center, ...) are not.
        var isUserApp = false
    }

    private typealias ResponsibleFunc = @convention(c) (pid_t) -> pid_t
    private let responsiblePID: ResponsibleFunc?
    private var cache: [pid_t: Owner] = [:]

    init() {
        responsiblePID = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
            .map { unsafeBitCast($0, to: ResponsibleFunc.self) }
    }

    func owner(pid: pid_t, bundleID: String) -> Owner {
        guard !bundleID.isEmpty else { return Owner(bundleID: bundleID, pid: pid) }
        if let cached = cache[pid] { return cached }
        var owner = resolve(pid: pid, bundleID: bundleID)
        if let app = NSRunningApplication(processIdentifier: owner.pid) {
            owner.isUserApp = Self.isUserApp(policy: app.activationPolicy, bundlePath: app.bundleURL?.path)
        }
        cache[pid] = owner
        return owner
    }

    /// Drops cached owners of processes that are gone (pids get reused).
    func retain(pids: Set<pid_t>) {
        cache = cache.filter { pids.contains($0.key) }
    }

    private func resolve(pid: pid_t, bundleID: String) -> Owner {
        if let path = Self.executablePath(pid: pid),
           let appPath = Self.outermostAppBundlePath(containing: path),
           let appBundleID = Bundle(path: appPath)?.bundleIdentifier {
            guard appBundleID != bundleID else { return Owner(bundleID: bundleID, pid: pid) }
            let appPID = NSRunningApplication.runningApplications(withBundleIdentifier: appBundleID).first?.processIdentifier
            return Owner(bundleID: appBundleID, pid: appPID ?? pid)
        }
        if let responsible = responsiblePID?(pid), responsible > 0, responsible != pid,
           let app = NSRunningApplication(processIdentifier: responsible),
           app.activationPolicy == .regular,
           let appBundleID = app.bundleIdentifier {
            return Owner(bundleID: appBundleID, pid: responsible)
        }
        return Owner(bundleID: bundleID, pid: pid)
    }

    nonisolated static func isUserApp(policy: NSApplication.ActivationPolicy, bundlePath: String?) -> Bool {
        switch policy {
        case .regular: true
        case .accessory: !(bundlePath ?? "/System/").hasPrefix("/System/")
        default: false
        }
    }

    /// "/Applications/Google Chrome.app/Contents/Frameworks/.../Google Chrome Helper.app/Contents/MacOS/x"
    /// -> "/Applications/Google Chrome.app"
    nonisolated static func outermostAppBundlePath(containing path: String) -> String? {
        let components = (path as NSString).pathComponents
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return NSString.path(withComponents: Array(components[...index]))
    }

    private static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
