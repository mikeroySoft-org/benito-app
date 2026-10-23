import XCTest
@testable import BenitoKit

final class NursingStartAdjustmentTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func books(
        frozenLeft: TimeInterval = 0,
        frozenRight: TimeInterval = 0,
        live: TimeInterval,
        active: String
    ) -> NursingDurationBooks {
        NursingDurationBooks(frozenLeft: frozenLeft, frozenRight: frozenRight, live: live, activeSide: active)
    }

    func testBothOnSingleSideMovesWholeLiveSegmentEarlier() {
        let plan = NursingStartAdjustment.plan(
            sessionStart: start,
            delta: 600,
            scope: .both,
            books: books(live: 120, active: "L")
        )
        XCTAssertEqual(plan.appliedDelta, 600, accuracy: 0.001)
        XCTAssertEqual(plan.live, 720, accuracy: 0.001)
        XCTAssertEqual(plan.liveDelta, 600, accuracy: 0.001)
        XCTAssertEqual(plan.frozenLeft, 0, accuracy: 0.001)
        XCTAssertEqual(plan.frozenRight, 0, accuracy: 0.001)
        XCTAssertEqual(plan.newSessionStart, start.addingTimeInterval(-600))
        XCTAssertEqual(plan.durationDelta, plan.appliedDelta, accuracy: 0.001)
    }

    func testLaterStartShrinksElapsed() {
        let plan = NursingStartAdjustment.plan(
            sessionStart: start,
            delta: -120,
            scope: .both,
            books: books(live: 600, active: "L")
        )
        XCTAssertEqual(plan.appliedDelta, -120, accuracy: 0.001)
        XCTAssertEqual(plan.live, 480, accuracy: 0.001)
        XCTAssertEqual(plan.liveDelta, -120, accuracy: 0.001)
        XCTAssertEqual(plan.newSessionStart, start.addingTimeInterval(120))
    }

    func testShrinkStopsAtZero() {
        let plan = NursingStartAdjustment.plan(
            sessionStart: start,
            delta: -10_000,
            scope: .left,
            books: books(live: 90, active: "L")
        )
        XCTAssertEqual(plan.appliedDelta, -90, accuracy: 0.001)
        XCTAssertEqual(plan.live, 0, accuracy: 0.001)
        XCTAssertEqual(plan.durationDelta, plan.appliedDelta, accuracy: 0.001)
    }

    func testExplicitOtherSideDoesNotMoveLiveTimer() {
        let plan = NursingStartAdjustment.plan(
            sessionStart: start,
            delta: 180,
            scope: .right,
            books: books(live: 100, active: "L")
        )
        XCTAssertEqual(plan.liveDelta, 0, accuracy: 0.001)
        XCTAssertEqual(plan.frozenRightDelta, 180, accuracy: 0.001)
        XCTAssertEqual(plan.live, 100, accuracy: 0.001)
        XCTAssertEqual(plan.frozenRight, 180, accuracy: 0.001)
        XCTAssertEqual(plan.durationDelta, 180, accuracy: 0.001)
    }

    func testBothSplitsWhenEachSideHasTime() {
        let plan = NursingStartAdjustment.plan(
            sessionStart: start,
            delta: 120,
            scope: .both,
            books: books(frozenLeft: 600, live: 300, active: "R")
        )
        XCTAssertEqual(plan.frozenLeftDelta, 60, accuracy: 0.001)
        XCTAssertEqual(plan.liveDelta, 60, accuracy: 0.001)
        XCTAssertEqual(plan.frozenRightDelta, 0, accuracy: 0.001)
        XCTAssertEqual(plan.live, 360, accuracy: 0.001)
        XCTAssertEqual(plan.frozenLeft, 660, accuracy: 0.001)
        XCTAssertEqual(plan.durationDelta, 120, accuracy: 0.001)
    }

    func testShrinkPastLiveEatsFrozenOnThatSide() {
        let plan = NursingStartAdjustment.plan(
            sessionStart: start,
            delta: -120,
            scope: .left,
            books: books(frozenLeft: 100, live: 50, active: "L")
        )
        XCTAssertEqual(plan.live, 0, accuracy: 0.001)
        XCTAssertEqual(plan.liveDelta, -50, accuracy: 0.001)
        XCTAssertEqual(plan.frozenLeft, 30, accuracy: 0.001)
        XCTAssertEqual(plan.frozenLeftDelta, -70, accuracy: 0.001)
        XCTAssertEqual(plan.durationDelta, -120, accuracy: 0.001)
    }

    func testBothShrinkRebalancesOntoTheLongerSide() {
        let plan = NursingStartAdjustment.plan(
            sessionStart: start,
            delta: -10,
            scope: .both,
            books: books(frozenLeft: 10, frozenRight: 0, live: 4, active: "R")
        )
        // Right only has 4s, so the rest of the 10s shrink comes off left.
        XCTAssertEqual(plan.frozenRight + plan.live, 0, accuracy: 0.001)
        XCTAssertEqual(plan.frozenLeft, 4, accuracy: 0.001)
        XCTAssertEqual(plan.appliedDelta, -10, accuracy: 0.001)
        XCTAssertEqual(plan.durationDelta, plan.appliedDelta, accuracy: 0.001)
    }
}
