import Foundation
import simd

// A saved pose is stored as 16 floats, in column-major order. It is not a
// relocalization map: a new AR session cannot safely extend this coordinate system.
struct SavedWallObservation: Codable {
    var timestamp: TimeInterval
    var transform: [Float]
    var trackingQuality: String
    var stabilityScore: Float

    init(_ value: WallObservation) {
        timestamp = value.timestamp
        let m = value.cameraTransform
        transform = [m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
                     m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
                     m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
                     m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w]
        trackingQuality = value.trackingQuality; stabilityScore = value.stabilityScore
    }
    func observation() -> WallObservation? {
        guard transform.count == 16, transform.allSatisfy(\.isFinite) else { return nil }
        let m = simd_float4x4(columns: (SIMD4(transform[0],transform[1],transform[2],transform[3]),
                                       SIMD4(transform[4],transform[5],transform[6],transform[7]),
                                       SIMD4(transform[8],transform[9],transform[10],transform[11]),
                                       SIMD4(transform[12],transform[13],transform[14],transform[15])))
        return WallObservation(timestamp: timestamp, cameraTransform: m, trackingQuality: trackingQuality, stabilityScore: stabilityScore)
    }
}
struct SavedSurveyWall: Codable {
    var pointX: Double; var pointZ: Double; var normalX: Double; var normalZ: Double
    var observations: [SavedWallObservation]
    init(_ wall: MeasuredWall) {
        pointX = wall.line.point.x; pointZ = wall.line.point.y
        normalX = wall.line.normal.x; normalZ = wall.line.normal.y
        observations = wall.observations.map(SavedWallObservation.init)
    }
    func wall() -> MeasuredWall {
        MeasuredWall(observations: observations.compactMap { $0.observation() }, line: WallLine(point: SIMD2(pointX, pointZ), normal: SIMD2(normalX, normalZ)))
    }
}
struct WallSurveyDraft: Codable, Identifiable {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var direction: String
    var offsetCentimeters: Double
    var walls: [SavedSurveyWall]
    var closureAccepted: Bool
    var closureResult: String?
    // Optional for drafts created before relocalization was introduced.
    var worldMapData: Data? = nil
    // Optional, deliberately taken by the user while the screen is visible.
    var referenceImageData: Data? = nil
    var captureMode: String? = nil
    var pendingObservation: SavedWallObservation? = nil
}

@MainActor final class WallSurveyDraftStore: ObservableObject {
    @Published private(set) var drafts: [WallSurveyDraft] = []
    @Published var error: String?
    private var readFailed = false
    private var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("wall-survey-drafts.json")
    }
    init() { reload() }
    func reload() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { drafts = try JSONDecoder().decode([WallSurveyDraft].self, from: Data(contentsOf: url)); error = nil; readFailed = false }
        catch { readFailed = true; self.error = "Impossible de lire les brouillons : \(error.localizedDescription)" }
    }
    @discardableResult func save(_ draft: WallSurveyDraft) -> Bool {
        // Never overwrite a file we failed to decode.
        if readFailed { return false }
        var updated = drafts
        if let index = updated.firstIndex(where: { $0.id == draft.id }) { updated[index] = draft }
        else { updated.append(draft) }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: url, options: .atomic)
            drafts = updated; error = nil; return true
        } catch { self.error = "Sauvegarde du brouillon impossible : \(error.localizedDescription)"; return false }
    }
}
