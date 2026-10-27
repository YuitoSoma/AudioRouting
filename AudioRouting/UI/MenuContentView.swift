import SwiftUI

struct MenuContentView: View {
    let router: RoutingManager
    let loginItem: LoginItemController

    private static let audioCaptureSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
    )!

    var body: some View {
        if router.permissionStatus != .authorized {
            permissionSection
            Divider()
        }

        let apps = listedApps
        Section("音を出しているアプリ") {
            if apps.isEmpty {
                Text("音を出しているアプリはありません")
            } else {
                ForEach(apps) { app in
                    appMenu(app)
                }
            }
        }

        Divider()

        loginItemSection

        Divider()

        Button("AudioRouting を終了") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// Apps playing now, plus running apps that have a saved route.
    private var listedApps: [AudioApp] {
        router.processMonitor.apps.filter { $0.isPlaying || router.selectedDeviceUID(for: $0.bundleID) != nil }
    }

    @ViewBuilder
    private var permissionSection: some View {
        Text("アプリ別の出力切り替えには「システム音声の録音」の許可が必要です")
        if router.permissionStatus == .denied {
            Button("システム設定で許可する…") {
                NSWorkspace.shared.open(Self.audioCaptureSettingsURL)
            }
        } else {
            Button("アクセスを許可…") {
                router.requestPermission()
            }
        }
    }

    @ViewBuilder
    private var loginItemSection: some View {
        Toggle("ログイン時に起動", isOn: Binding(
            get: { loginItem.isOn },
            set: { loginItem.setEnabled($0) }
        ))
        if loginItem.status == .requiresApproval {
            Button("ログイン項目をシステム設定で許可…") {
                loginItem.openSystemSettings()
            }
        }
        if let error = loginItem.lastError {
            Text("ログイン時の起動を変更できませんでした: \(error)")
        }
    }

    private func appMenu(_ app: AudioApp) -> some View {
        let selection = Binding<String?>(
            get: { router.selectedDeviceUID(for: app.bundleID) },
            set: { router.setOutput(app: app.bundleID, deviceUID: $0) }
        )
        return Menu(menuTitle(app)) {
            if case .failed(_, let message) = router.status(for: app.bundleID) {
                Text("切り替えに失敗しました: \(message)")
                Text("出力先をもう一度選ぶと再試行します")
                Divider()
            }
            Picker("出力先", selection: selection) {
                Text("既定の出力").tag(String?.none)
                ForEach(router.deviceMonitor.devices) { device in
                    Text(device.name).tag(String?.some(device.uid))
                }
                if let uid = selection.wrappedValue, router.deviceMonitor.device(uid: uid) == nil {
                    Text("\(uid)（未接続）").tag(String?.some(uid))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    private func menuTitle(_ app: AudioApp) -> String {
        switch router.status(for: app.bundleID) {
        case .systemDefault:
            return app.name
        case .routed(let uid):
            return "\(app.name) → \(deviceName(uid))"
        case .deviceMissing(let uid):
            return "\(app.name) → \(deviceName(uid))（未接続・既定の出力で再生中）"
        case .failed(let uid, _):
            return "\(app.name) → \(deviceName(uid))（切り替えに失敗）"
        case .needsPermission(let uid):
            return "\(app.name) → \(deviceName(uid))（許可待ち）"
        }
    }

    private func deviceName(_ uid: String) -> String {
        router.deviceMonitor.device(uid: uid)?.name ?? uid
    }
}
