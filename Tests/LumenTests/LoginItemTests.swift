import Foundation
import ServiceManagement

@testable import LumenKit

@MainActor
private final class MockLoginItemService: LoginItemServicing {
    var status: SMAppService.Status = .notRegistered
    var registrationStatus: SMAppService.Status = .enabled
    var shouldFail = false
    var registrationCalls = 0
    var unregisterCalls = 0

    func register() throws {
        registrationCalls += 1
        if shouldFail { throw NSError(domain: "test", code: 1) }
        status = registrationStatus
    }

    func unregister() throws {
        unregisterCalls += 1
        if shouldFail { throw NSError(domain: "test", code: 2) }
        status = .notRegistered
    }
}

@MainActor
func runLoginItemTests() async {
    await runTest("login item: failure leaves the toggle aligned with the actual service") {
        let service = MockLoginItemService()
        let controller = LoginItemController(service: service, canManage: true)
        service.shouldFail = true
        controller.setEnabled(true)
        check(!controller.isEnabled, "failed registration not presented as enabled")
        check(controller.lastError != nil, "failure is actionable")
        service.status = .enabled
        controller.setEnabled(false)
        check(controller.isEnabled, "failed unregistration still shown as registered")
    }

    await runTest("login item: successful registration can still require approval") {
        let service = MockLoginItemService()
        service.registrationStatus = .requiresApproval
        let controller = LoginItemController(service: service, canManage: true)
        controller.setEnabled(true)
        check(controller.needsApproval, "approval state reconciled after success")
        check(controller.statusDescription.contains("Approval"), "approval explained")
        service.status = .notRegistered
        controller.refresh()
        check(!controller.isEnabled, "external disabling reflected after refresh")
    }

    await runTest("login item: debug mode cannot pretend to register") {
        let service = MockLoginItemService()
        let controller = LoginItemController(service: service, canManage: false)
        controller.setEnabled(true)
        checkEqual(service.registrationCalls, 0, "no registration side effects")
        check(!controller.isEnabled, "actual status retained")
        check(controller.lastError != nil, "debug limitation explained")
    }
}
