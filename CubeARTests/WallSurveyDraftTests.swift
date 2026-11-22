import XCTest
import simd
@testable import CubeAR

final class WallSurveyDraftTests: XCTestCase {
    func testDraftKeepsWallAndRawPoseThroughEncoding() throws {
        var matrix = matrix_identity_float4x4
        matrix.columns.3 = SIMD4<Float>(1, 2, 3, 1)
        let observation = WallObservation(timestamp: 12, cameraTransform: matrix, trackingQuality: "normal", stabilityScore: 0.01)
        let wall = MeasuredWall(observations: [observation], line: WallLine(point: SIMD2(1, 3), normal: SIMD2(0, 1)))
        let draft = WallSurveyDraft(id: UUID(), createdAt: Date(), updatedAt: Date(), direction: SurveyDirection.clockwise.rawValue, offsetCentimeters: 1, walls: [SavedSurveyWall(wall)], closureAccepted: false, closureResult: nil)
        let restored = try JSONDecoder().decode(WallSurveyDraft.self, from: JSONEncoder().encode(draft))
        XCTAssertEqual(restored.walls.count, 1)
        XCTAssertEqual(restored.walls[0].wall().line.point, SIMD2(1, 3))
        let pose = try XCTUnwrap(restored.walls[0].observations[0].observation())
        XCTAssertEqual(pose.cameraTransform.columns.3.x, 1, accuracy: 0.001)
        XCTAssertEqual(pose.cameraTransform.columns.3.z, 3, accuracy: 0.001)
        XCTAssertFalse(restored.closureAccepted)
    }

    func testMalformedPoseIsNotDecodedAsIdentity() {
        let observation = WallObservation(timestamp: 0, cameraTransform: matrix_identity_float4x4, trackingQuality: "normal", stabilityScore: 0)
        var saved = SavedWallObservation(observation)
        saved.transform = [1, 2]
        XCTAssertNil(saved.observation())
    }

    func testDraftKeepsOptionalMapAndReadsLegacyDraft() throws {
        var draft = WallSurveyDraft(id: UUID(), createdAt: Date(), updatedAt: Date(), direction: SurveyDirection.clockwise.rawValue, offsetCentimeters: 1, walls: [], closureAccepted: false, closureResult: nil)
        let legacy = try JSONEncoder().encode(draft)
        XCTAssertNil(try JSONDecoder().decode(WallSurveyDraft.self, from: legacy).worldMapData)
        draft.worldMapData = Data([1, 2, 3])
        draft.referenceImageData = Data([4, 5, 6])
        let restored = try JSONDecoder().decode(WallSurveyDraft.self, from: JSONEncoder().encode(draft))
        XCTAssertEqual(restored.worldMapData, draft.worldMapData)
        XCTAssertEqual(restored.referenceImageData, draft.referenceImageData)
    }
}
