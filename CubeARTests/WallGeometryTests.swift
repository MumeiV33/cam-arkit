import XCTest
import simd
@testable import CubeAR

final class WallGeometryTests: XCTestCase {
    let settings = SurveySettings()
    func wall(_ x: Double, _ z: Double, _ nx: Double, _ nz: Double) -> MeasuredWall {
        MeasuredWall(observations: [], line: WallLine(point: SIMD2(x,z), normal: simd_normalize(SIMD2(nx,nz))))
    }
    func testRectangleAndReversedTraversal() {
        let walls = [wall(0,0,0,1), wall(4,0,1,0), wall(4,3,0,1), wall(0,3,1,0)]
        for input in [walls, walls.reversed().map { $0 }] {
            let result = WallGeometry.geometry(input, closed: true, settings: settings)
            XCTAssertNil(result.error); XCTAssertEqual(result.corners.count, 4)
            XCTAssertEqual(result.lengths.reduce(0,+), 14, accuracy: 0.001)
            result.angles.forEach { XCTAssertEqual($0, 90, accuracy: 0.001) }
        }
    }
    func testWallNumbersMatchMeasuredLinesAndPlan() {
        let walls = [wall(0,0,0,1), wall(4,0,1,0), wall(4,3,0,1), wall(0,3,1,0)]
        let result = WallGeometry.geometry(walls, closed: true, settings: settings)
        XCTAssertEqual(result.lengths[0], 4, accuracy: 0.001)
        XCTAssertEqual(result.lengths[1], 3, accuracy: 0.001)
        let elements = WallGeometry.planElements(result, height: 2.5)
        XCTAssertEqual(elements.count, 4)
        XCTAssertEqual(elements[0].width, 4, accuracy: 0.001)
        XCTAssertEqual(elements[0].z, 0, accuracy: 0.001)
        XCTAssertEqual(elements[1].x, 4, accuracy: 0.001)
        XCTAssertEqual(elements[0].height ?? 0, 2.5, accuracy: 0.001)
    }
    func testParallelAndNearlyParallel() {
        let a = wall(0,0,0,1).line
        XCTAssertNil(WallGeometry.intersection(a, wall(0,1,0,1).line, settings: settings))
        XCTAssertNil(WallGeometry.intersection(a, wall(0,1,0.01,1).line, settings: settings))
    }
    func testNextWallRejectsDuplicateAndUnusableIntersection() {
        let first = wall(0, 0, 0, 1)
        XCTAssertNotNil(WallGeometry.nextWallProblem(wall(2, 0.02, 0, 1).line, after: [first], settings: settings))
        XCTAssertNotNil(WallGeometry.nextWallProblem(wall(0, 3, 0, 1).line, after: [first], settings: settings))
        XCTAssertNil(WallGeometry.nextWallProblem(wall(4, 0, 1, 0).line, after: [first], settings: settings))
    }
    func testTwoPointWallWithReversedNormalAndDifferentOrder() throws {
        let first = wall(0, 0, 0, 1).line
        let second = wall(2, 0, 0, -1).line
        let line = try XCTUnwrap(WallGeometry.twoPointWall(first, second).line)
        let reversed = try XCTUnwrap(WallGeometry.twoPointWall(second, first).line)
        XCTAssertEqual(line.point.x, 1, accuracy: 0.001)
        XCTAssertEqual(abs(simd_dot(line.normal, reversed.normal)), 1, accuracy: 0.001)
        XCTAssertEqual(WallGeometry.closure(line, first).distance, 0, accuracy: 0.001)
    }
    func testTwoPointWallRejectsShortBaselineAndInconsistentPoses() {
        let first = wall(0, 0, 0, 1).line
        XCTAssertNil(WallGeometry.twoPointWall(first, wall(0.2, 0, 0, 1).line).line)
        XCTAssertNil(WallGeometry.twoPointWall(first, wall(2, 0, 1, 0).line).line)
        XCTAssertNil(WallGeometry.twoPointWall(first, wall(0, 2, 0, 1).line).line)
    }
    func testClosureDifferentLocationsAndErrors() {
        let first = wall(0,0,0,1).line
        XCTAssertEqual(WallGeometry.closure(first, wall(3,0,0,-1).line).distance, 0, accuracy: 0.001)
        XCTAssertEqual(WallGeometry.closure(first, wall(3,0.3,0,1).line).distance, 0.3, accuracy: 0.001)
        XCTAssertGreaterThan(WallGeometry.closure(first, wall(0,0,0.2,1).line).angle, 10)
    }
    func testClosureAcceptsValidGeometryEvenIfChosenDirectionDiffers() throws {
        let walls = [wall(0,0,0,1), wall(4,0,1,0), wall(4,3,0,1), wall(0,3,1,0)]
        let clockwise = try XCTUnwrap(WallGeometry.assessClosure(walls: walls, check: walls[0].line, direction: .clockwise, settings: settings))
        let counterclockwise = try XCTUnwrap(WallGeometry.assessClosure(walls: walls, check: walls[0].line, direction: .counterclockwise, settings: settings))
        XCTAssertTrue(clockwise.accepted); XCTAssertTrue(counterclockwise.accepted)
        XCTAssertNotEqual(clockwise.directionWarning, counterclockwise.directionWarning)
    }
    func testClosureRejectsInconsistentFirstWallDespiteValidContour() throws {
        let walls = [wall(0,0,0,1), wall(4,0,1,0), wall(4,3,0,1), wall(0,3,1,0)]
        let assessment = try XCTUnwrap(WallGeometry.assessClosure(walls: walls, check: wall(0, 0.3, 0, 1).line, direction: .clockwise, settings: settings))
        XCTAssertFalse(assessment.accepted); XCTAssertNil(assessment.contourError)
    }
    func testConcaveAndNonOrthogonal() {
        let walls = [wall(0,0,0,1),wall(4,0,1,0),wall(4,1,0,1),wall(2,1,1,0),wall(2,3,0,1),wall(0,3,1,0)]
        let geometry = WallGeometry.geometry(walls, closed: true, settings: settings)
        XCTAssertNil(geometry.error); XCTAssertTrue(geometry.angles.contains { $0 > 180 })
        XCTAssertNotNil(WallGeometry.intersection(wall(0,0,0,1).line, wall(1,0,1,1).line, settings: settings))
    }
    func testCrossedSegments() {
        XCTAssertTrue(WallGeometry.intersects(SIMD2(0,0), SIMD2(2,2), SIMD2(0,2), SIMD2(2,0)))
        XCTAssertFalse(WallGeometry.intersects(SIMD2(0,0), SIMD2(1,0), SIMD2(2,0), SIMD2(3,0)))
    }
    func testTiltedPhoneUsesFullNormal() {
        let q = simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(1,0,0))
        let transform = simd_float4x4(q)
        let line = WallGeometry.line(transform: transform, offset: 0.01)
        XCTAssertNotNil(line); XCTAssertEqual(line!.normal.y, 1, accuracy: 0.001)
    }
}
