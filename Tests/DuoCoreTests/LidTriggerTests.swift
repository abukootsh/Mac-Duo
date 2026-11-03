import XCTest
@testable import DuoCore
import simd

final class LidTriggerTests: XCTestCase {

    private func makeTrigger(start: Double = 90, timeout: Bool = false) -> LidTrigger {
        LidTrigger(configuration: .init(startAngle: start, timeoutEnabled: timeout))
    }

    /// Feeds a straight sweep at 10 Hz and returns the time after the last sample.
    @discardableResult
    private func sweep(
        _ trigger: inout LidTrigger, from: Double, to: Double,
        seconds: Double, startingAt t0: Double = 0
    ) -> Double {
        let steps = Int(seconds * 10)
        for i in 0...steps {
            let f = Double(i) / Double(steps)
            trigger.update(angle: from + (to - from) * f, at: t0 + Double(i) * 0.1)
        }
        return t0 + Double(steps) * 0.1 + 0.1
    }

    private func hold(_ trigger: inout LidTrigger, at angle: Double, seconds: Double, startingAt t0: Double) -> Double {
        var t = t0
        while t < t0 + seconds {
            trigger.update(angle: angle, at: t)
            t += 0.1
        }
        return t
    }

    func testClosingPastStartAngleStartsEffect() {
        var trigger = makeTrigger()
        sweep(&trigger, from: 120, to: 60, seconds: 2)
        XCTAssertTrue(trigger.isActive)
    }

    func testRestingBelowStartAngleDoesNotStart() {
        var trigger = makeTrigger()
        _ = hold(&trigger, at: 60, seconds: 3, startingAt: 0)
        XCTAssertFalse(trigger.isActive)
    }

    func testOpeningBelowStartAngleDoesNotStart() {
        var trigger = makeTrigger()
        sweep(&trigger, from: 20, to: 80, seconds: 2)
        XCTAssertFalse(trigger.isActive)
    }

    func testHoldingClosedKeepsEffect() {
        var trigger = makeTrigger()
        let t = sweep(&trigger, from: 120, to: 50, seconds: 2)
        _ = hold(&trigger, at: 50, seconds: 5, startingAt: t)
        XCTAssertTrue(trigger.isActive)
    }

    func testOpeningBackReleasesEffect() {
        var trigger = makeTrigger()
        var t = sweep(&trigger, from: 120, to: 50, seconds: 2)
        t = sweep(&trigger, from: 50, to: 110, seconds: 1, startingAt: t)
        XCTAssertFalse(trigger.isActive)
    }

    func testSlowOpeningAboveStartReleasesThroughDwell() {
        var trigger = makeTrigger()
        var t = sweep(&trigger, from: 120, to: 85, seconds: 2)
        XCTAssertTrue(trigger.isActive)
        t = hold(&trigger, at: 91, seconds: 1.5, startingAt: t)
        XCTAssertFalse(trigger.isActive)
    }

    func testTimeoutEndsEffectAndDoesNotRetrigger() {
        var trigger = makeTrigger(timeout: true)
        var t = sweep(&trigger, from: 120, to: 50, seconds: 2)
        XCTAssertTrue(trigger.isActive)
        t = hold(&trigger, at: 50, seconds: 3, startingAt: t)
        XCTAssertFalse(trigger.isActive)
        // Closing further from the same spot must not start it again.
        t = sweep(&trigger, from: 50, to: 30, seconds: 1, startingAt: t)
        XCTAssertFalse(trigger.isActive)
        // Opening above the start angle rearms it.
        t = sweep(&trigger, from: 30, to: 120, seconds: 1, startingAt: t)
        t = hold(&trigger, at: 120, seconds: 0.5, startingAt: t)
        sweep(&trigger, from: 120, to: 60, seconds: 1.5, startingAt: t)
        XCTAssertTrue(trigger.isActive)
    }

    func testPrewarmWhileClosingAboveStart() {
        var trigger = makeTrigger()
        let t = sweep(&trigger, from: 130, to: 100, seconds: 1)
        XCTAssertFalse(trigger.isActive)
        XCTAssertTrue(trigger.wantsPrewarm(at: t))
        XCTAssertFalse(trigger.wantsPrewarm(at: t + 5))
    }

    func testResetForgetsHistory() {
        var trigger = makeTrigger()
        sweep(&trigger, from: 120, to: 60, seconds: 2)
        trigger.reset(angle: 60)
        XCTAssertFalse(trigger.isActive)
        trigger.update(angle: 59, at: 10)
        XCTAssertFalse(trigger.isActive)
    }
}

final class ProjectionTests: XCTestCase {

    func testFlatAtStartAngle() {
        let corners = DepthProjection.corners(
            startAngle: 90, currentAngle: 90, viewingDistance: 3, lean: 1, width: 1440, height: 900
        )
        let expected: [SIMD2<Double>] = [[0, 0], [1440, 0], [1440, 900], [0, 900]]
        for (a, b) in zip(corners, expected) {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-6)
            XCTAssertEqual(a.y, b.y, accuracy: 1e-6)
        }
    }

    func testTopEdgeShrinksAsLidCloses() {
        let corners = DepthProjection.corners(
            startAngle: 90, currentAngle: 60, viewingDistance: 3, lean: 1, width: 1440, height: 900
        )
        let topWidth = corners[2].x - corners[3].x
        XCTAssertLessThan(topWidth, 1440)
        XCTAssertEqual(corners[1].x - corners[0].x, 1440, accuracy: 1e-6)
    }

    func testHomographyMapsCorners() {
        let quad: [SIMD2<Double>] = [[10, 0], [990, 5], [800, 600], [200, 620]]
        let m = DepthProjection.homography(width: 1000, height: 700, corners: quad)
        let rect: [SIMD2<Double>] = [[0, 0], [1000, 0], [1000, 700], [0, 700]]
        for (p, q) in zip(rect, quad) {
            let r = m * SIMD3(p.x, p.y, 1)
            XCTAssertEqual(r.x / r.z, q.x, accuracy: 1e-6)
            XCTAssertEqual(r.y / r.z, q.y, accuracy: 1e-6)
        }
    }

    func testSpringSettles() {
        var spring = Spring(value: 0)
        for _ in 0..<240 { spring.step(toward: 10, dt: 1.0 / 60) }
        XCTAssertEqual(spring.value, 10, accuracy: 0.01)
    }
}
