import Foundation

// Independent of ARKit: local room coordinates are never assumed to share an origin.
struct HousingPoint: Codable, Equatable {
    var x: Double
    var z: Double
}

struct HousingTransform: Codable, Equatable {
    var x: Double = 0
    var z: Double = 0
    var rotation: Double = 0

    func applying(to point: HousingPoint) -> HousingPoint {
        HousingPoint(x: x + cos(rotation) * point.x - sin(rotation) * point.z,
                     z: z + sin(rotation) * point.x + cos(rotation) * point.z)
    }
}

enum RoomCaptureMethod: String, Codable { case lidar, contact, manual }
enum OpeningType: String, Codable, CaseIterable { case door, window, frenchDoor }
enum OpeningMeasurement: String, Codable { case manual, camera, contact, lidar }

struct HousingOpening: Codable, Identifiable {
    var id = UUID()
    var wallID: UUID
    var type: OpeningType
    // Distance in metres from the wall's start, not its midpoint.
    var offset: Double
    var width: Double
    var height: Double?
    var sillHeight: Double?
    var measurement: OpeningMeasurement
    var confidence: String?
    var connectedRoomID: UUID?

    func fits(on wall: HousingWall) -> Bool {
        wallID == wall.id && offset.isFinite && width.isFinite && offset >= 0 && width > 0 && offset + width <= wall.length
    }
}

struct HousingWall: Codable, Identifiable {
    var id = UUID()
    var start: HousingPoint
    var end: HousingPoint
    var thickness: Double?
    var length: Double { hypot(end.x - start.x, end.z - start.z) }
}

struct HousingRoom: Codable, Identifiable {
    var id = UUID()
    var name: String
    var walls: [HousingWall]
    var openings: [HousingOpening] = []
    var captureMethod: RoomCaptureMethod
    var floorElevation: Double = 0
    var levelID: UUID?
    var localToGlobal = HousingTransform()
    // A new session needs user-confirmed alignment before appearing in a global plan.
    var alignmentConfirmed = false
    var captureQuality: String?
}

struct HousingLevel: Codable, Identifiable {
    var id = UUID()
    var name: String
    var referenceElevation: Double
}

struct HousingProject: Codable, Identifiable {
    var id = UUID()
    var name: String
    var rooms: [HousingRoom] = []
    var levels: [HousingLevel] = []
}
