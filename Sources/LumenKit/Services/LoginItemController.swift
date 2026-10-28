import Foundation
import ServiceManagement

@MainActor
protocol LoginItemServicing {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

@MainActor
private struct SystemLoginItemService: LoginItemServicing {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

/// Reconciles against macOS after every operation, including successful calls
/// that only move registration into the "requires approval" state.
@MainActor
@Observable
final class LoginItemController {
    private(set) var status: SMAppService.Status
    private(set) var lastError: String?
    let canManage: Bool
    private let service: any LoginItemServicing

    private static var defaultCanManage: Bool {
        #if DEBUG
            false
        #else
            true
        #endif
    }

    init(service: (any LoginItemServicing)? = nil, canManage: Bool? = nil) {
        let service = service ?? SystemLoginItemService()
        self.service = service
        self.canManage = canManage ?? Self.defaultCanManage
        status = service.status
    }

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    var statusDescription: String {
        guard canManage else { return "Login-item changes are disabled in debug builds. Use a packaged release build." }
        switch status {
        case .enabled: return "Launch at login is enabled in macOS."
        case .requiresApproval: return "Approval is required in System Settings before Lumen can launch at login."
        case .notRegistered: return "Launch at login is disabled."
        case .notFound: return "macOS could not find the app. Move Lumen to Applications and try again."
        @unknown default: return "Login-item status is unavailable."
        }
    }

    func refresh() {
        lastError = nil
        status = service.status
    }

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        guard canManage else {
            status = service.status
            lastError = statusDescription
            return
        }
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            lastError = "Login item failed: \(error.localizedDescription)"
        }
        // Even a successful request is not proof the service is enabled.
        status = service.status
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
