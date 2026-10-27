import XCTest
@testable import AudioRouting

@MainActor
final class LoginItemControllerTests: XCTestCase {
    func testOffByDefault() {
        XCTAssertFalse(LoginItemController(service: MockLoginItemService()).isOn)
    }

    func testTurnOnAndOff() {
        let service = MockLoginItemService()
        let controller = LoginItemController(service: service)

        controller.setEnabled(true)
        XCTAssertTrue(controller.isOn)
        XCTAssertEqual(service.status, .enabled)

        controller.setEnabled(false)
        XCTAssertFalse(controller.isOn)
        XCTAssertEqual(service.status, .disabled)
    }

    func testRequiresApprovalCountsAsOnAndOffersSettings() {
        let service = MockLoginItemService()
        service.statusAfterRegister = .requiresApproval
        let controller = LoginItemController(service: service)

        controller.setEnabled(true)

        XCTAssertTrue(controller.isOn)
        XCTAssertEqual(controller.status, .requiresApproval)
        controller.openSystemSettings()
        XCTAssertTrue(service.openedSettings)
    }

    func testFailureIsReportedAndStateUnchanged() {
        let service = MockLoginItemService()
        service.failNext = true
        let controller = LoginItemController(service: service)

        controller.setEnabled(true)

        XCTAssertFalse(controller.isOn)
        XCTAssertNotNil(controller.lastError)

        controller.setEnabled(true)
        XCTAssertNil(controller.lastError, "a later success clears the error")
    }
}
