import Foundation
import Observation
import os
import ServiceManagement

enum LoginItemStatus: Equatable, Sendable {
    case enabled
    case disabled
    /// Registered, but the user must allow it in System Settings > General > Login Items.
    case requiresApproval
    case unavailable
}

@MainActor
protocol LoginItemService: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

/// The real login item: this app itself, via SMAppService.
@MainActor
final class MainAppLoginItemService: LoginItemService {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .notRegistered: .disabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// "Start at login" toggle state for the menu. Off unless the user turns it on.
@MainActor
@Observable
final class LoginItemController {
    private(set) var status: LoginItemStatus
    private(set) var lastError: String?

    @ObservationIgnored private let service: LoginItemService
    @ObservationIgnored private let logger = Logger(subsystem: "local.audiorouting", category: "LoginItem")

    init(service: LoginItemService) {
        self.service = service
        status = service.status
    }

    /// On for both enabled and waiting-for-approval, so the toggle reflects what the user chose.
    var isOn: Bool { status == .enabled || status == .requiresApproval }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled { try service.register() } else { try service.unregister() }
            lastError = nil
        } catch {
            logger.error("login item \(enabled ? "register" : "unregister"): \(error)")
            lastError = error.localizedDescription
        }
        refresh()
    }

    func refresh() {
        status = service.status
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }
}
