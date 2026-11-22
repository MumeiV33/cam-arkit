import XCTest
@testable import CubeAR

final class HousingModelTests: XCTestCase {
    func testOpeningMustFitItsWall() {
        let wall = HousingWall(start: HousingPoint(x: 0, z: 0), end: HousingPoint(x: 4, z: 0))
        var door = HousingOpening(wallID: wall.id, type: .door, offset: 1, width: 0.9, measurement: .manual)
        XCTAssertTrue(door.fits(on: wall))
        door.offset = 3.5
        XCTAssertFalse(door.fits(on: wall))
    }

    func testProjectRoundTripKeepsRoomAndAlignment() throws {
        let wall = HousingWall(start: HousingPoint(x: 0, z: 0), end: HousingPoint(x: 2, z: 0))
        let room = HousingRoom(name: "Salon", walls: [wall], captureMethod: .contact,
                               localToGlobal: HousingTransform(x: 4, z: 2, rotation: .pi / 2), alignmentConfirmed: true)
        let saved = HousingProject(name: "Maison", rooms: [room])
        let loaded = try JSONDecoder().decode(HousingProject.self, from: JSONEncoder().encode(saved))
        let point = loaded.rooms[0].localToGlobal.applying(to: HousingPoint(x: 1, z: 0))
        XCTAssertEqual(point.x, 4, accuracy: 0.0001)
        XCTAssertEqual(point.z, 3, accuracy: 0.0001)
        XCTAssertTrue(loaded.rooms[0].alignmentConfirmed)
    }
}
