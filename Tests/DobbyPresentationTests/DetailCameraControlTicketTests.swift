// Created by mason on 11/11/26.
import XCTest
@testable import Dobby

final class DetailCameraControlTicketTests: XCTestCase {
    func testSessionChangeRejectsCommandsCreatedBeforeWhiteBalanceWait() throws {
        let epoch = DetailCameraControlEpoch()
        let zoom = epoch.ticket()
        let focus = epoch.ticket()
        try zoom.checkCancellation()
        epoch.invalidate() // WB 대기 중 촬영 시작 또는 세션 종료
        XCTAssertThrowsError(try zoom.checkCancellation()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try focus.checkCancellation()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertNoThrow(try epoch.ticket().checkCancellation())
    }

    func testCancellingOneCommandDoesNotCancelAnotherCommand() throws {
        let epoch = DetailCameraControlEpoch()
        let cancelled = epoch.ticket()
        let remaining = epoch.ticket()
        cancelled.cancel()
        cancelled.cancel()
        XCTAssertThrowsError(try cancelled.checkCancellation()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertNoThrow(try remaining.checkCancellation())
    }

    func testOldCompletionCannotInvalidateNewSessionTicket() throws {
        let epoch = DetailCameraControlEpoch()
        let old = epoch.ticket()
        epoch.invalidate()
        let current = epoch.ticket()
        old.cancel() // 이전 비동기 작업의 늦은 취소 처리
        XCTAssertNoThrow(try current.checkCancellation())
        XCTAssertThrowsError(try old.checkCancellation())
    }
}
