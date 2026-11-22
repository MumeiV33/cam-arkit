import XCTest
@testable import CubeAR

final class PlanAreaTests: XCTestCase {
    private func wall(_ x: Double, _ z: Double, _ width: Double, _ angle: Double) -> PlanElement {
        PlanElement(kind: .wall, title: "Mur", x: x, z: z, width: width, depth: 0.1, rotation: angle)
    }
    func testRectangleWithUnorderedWalls() throws {
        let walls = [wall(2, 0, 4, 0), wall(0, 1.5, 3, .pi / 2), wall(2, 3, 4, 0), wall(4, 1.5, 3, .pi / 2)]
        XCTAssertEqual(try XCTUnwrap(PlanArea.area(walls: walls)), 12, accuracy: 0.001)
    }
    func testOpenAndSelfIntersectingContoursHaveNoArea() {
        let open = [wall(2, 0, 4, 0), wall(4, 1.5, 3, .pi / 2), wall(2, 3, 4, 0)]
        XCTAssertNil(PlanArea.area(walls: open))
        let diagonal = sqrt(8.0)
        let crossed = [wall(1, 1, diagonal, .pi / 4), wall(1, 2, 2, 0), wall(1, 1, diagonal, -.pi / 4), wall(1, 0, 2, 0)]
        XCTAssertNil(PlanArea.area(walls: crossed))
    }
}
