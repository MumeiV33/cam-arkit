import Foundation
import simd

enum SurveyDirection: String, CaseIterable { case clockwise = "Horaire", counterclockwise = "Antihoraire" }
enum WallCaptureMode: String, CaseIterable { case single = "Une prise", twoPoints = "Deux points espacés" }
struct SurveySettings {
    // Heuristic thresholds, not calibrated measurement uncertainty.
    var screenOffset: Float = 0.01
    var maxMotion: Float = 0.015
    var maxRotation: Float = 0.035
    var minIntersectionSin: Double = 0.10
    var maxCornerDistance: Double = 10
    var goodClosureDistance: Double = 0.10
    var goodClosureAngle: Double = 5
    var uncertainClosureDistance: Double = 0.25
    var uncertainClosureAngle: Double = 12
}
struct WallObservation {
    let id = UUID()
    let timestamp: TimeInterval
    let cameraTransform: simd_float4x4
    let trackingQuality: String
    let stabilityScore: Float
}
struct WallLine {
    let point: SIMD2<Double>
    let normal: SIMD2<Double>
    var direction: SIMD2<Double> { SIMD2(-normal.y, normal.x) }
}
struct MeasuredWall: Identifiable {
    let id = UUID()
    var observations: [WallObservation]
    var line: WallLine
}
struct SurveyGeometry {
    var corners: [SIMD2<Double>]
    var lengths: [Double]
    var angles: [Double]
    var error: String?
}
struct ClosureAssessment {
    let wallConsistent: Bool
    let contourError: String?
    let directionWarning: Bool
    let distance: Double
    let angle: Double
    var accepted: Bool { wallConsistent && contourError == nil }
}
enum WallGeometry {
    static func assessClosure(walls: [MeasuredWall], check: WallLine, direction: SurveyDirection, settings: SurveySettings) -> ClosureAssessment? {
        guard let first = walls.first, walls.count >= 3 else { return nil }
        let comparison = closure(first.line, check)
        let result = geometry(walls, closed: true, settings: settings)
        let points = result.corners
        let area = points.indices.reduce(0.0) { total, index in total + cross(points[index], points[(index + 1) % points.count]) }
        let directionWarning = result.error == nil && points.count >= 3 && ((area > 0) != (direction == .clockwise))
        return ClosureAssessment(wallConsistent: comparison.distance <= settings.goodClosureDistance && comparison.angle <= settings.goodClosureAngle,
                                 contourError: result.error, directionWarning: directionWarning,
                                 distance: comparison.distance, angle: comparison.angle)
    }
    static func twoPointWall(_ a: WallLine, _ b: WallLine) -> (line: WallLine?, error: String?) {
        let delta = b.point - a.point
        let distance = simd_length(delta)
        guard distance >= 0.30 else { return (nil, "Points trop proches : espacez les prises d’au moins 30 cm sur le même mur.") }
        let direction = delta / distance
        let alignment = abs(simd_dot(a.normal, b.normal))
        guard alignment >= cos(15 * Double.pi / 180) else { return (nil, "Orientations trop différentes : plaquez l’écran sur la même face du mur et réessayez.") }
        let maxNormalAlongWall = sin(15 * Double.pi / 180)
        guard abs(simd_dot(a.normal, direction)) <= maxNormalAlongWall && abs(simd_dot(b.normal, direction)) <= maxNormalAlongWall else {
            return (nil, "Positions et orientations incohérentes : vérifiez que les deux prises sont sur le même mur, puis réessayez.")
        }
        var normal = SIMD2(-direction.y, direction.x)
        if simd_dot(normal, a.normal) < 0 { normal = -normal }
        return (WallLine(point: (a.point + b.point) / 2, normal: normal), nil)
    }
    // AR camera local +Z points toward the screen. Offset is an approximation,
    // not an Apple-supplied camera-to-glass calibration.
    static func line(transform: simd_float4x4, offset: Float) -> WallLine? {
        let forward = SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        let horizontal = SIMD2<Double>(Double(forward.x), Double(forward.z))
        let magnitude = simd_length(horizontal)
        guard magnitude > 0.7 else { return nil }
        let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z) + forward * offset
        return WallLine(point: SIMD2(Double(position.x), Double(position.z)), normal: horizontal / magnitude)
    }
    static func intersection(_ a: WallLine, _ b: WallLine, settings: SurveySettings) -> SIMD2<Double>? {
        let d = a.direction, e = b.direction
        let det = d.x * e.y - d.y * e.x
        guard abs(det) >= settings.minIntersectionSin else { return nil }
        let delta = b.point - a.point
        let t = (delta.x * e.y - delta.y * e.x) / det
        let p = a.point + t * d
        guard simd_distance(p, a.point) <= settings.maxCornerDistance, simd_distance(p, b.point) <= settings.maxCornerDistance else { return nil }
        return p
    }
    static func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x*b.y - a.y*b.x }
    static func intersects(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>, _ d: SIMD2<Double>) -> Bool {
        let ab = b-a, cd = d-c
        let eps = 1e-8
        let c1 = cross(ab,c-a), c2 = cross(ab,d-a), c3 = cross(cd,a-c), c4 = cross(cd,b-c)
        func onSegment(_ p: SIMD2<Double>, _ q: SIMD2<Double>, _ r: SIMD2<Double>) -> Bool {
            abs(cross(q-p,r-p)) < eps && r.x >= min(p.x,q.x)-eps && r.x <= max(p.x,q.x)+eps && r.y >= min(p.y,q.y)-eps && r.y <= max(p.y,q.y)+eps
        }
        return (c1*c2 < -eps && c3*c4 < -eps) || onSegment(a,b,c) || onSegment(a,b,d) || onSegment(c,d,a) || onSegment(c,d,b)
    }
    static func geometry(_ walls: [MeasuredWall], closed: Bool, settings: SurveySettings) -> SurveyGeometry {
        guard walls.count >= 2 else { return SurveyGeometry(corners: [], lengths: [], angles: [], error: nil) }
        let count = closed ? walls.count : walls.count - 1
        var corners: [SIMD2<Double>] = []
        for i in 0..<count {
            guard let p = intersection(walls[i].line, walls[(i+1)%walls.count].line, settings: settings) else { return SurveyGeometry(corners: corners, lengths: [], angles: [], error: "Murs \(i+1) et \((i+1)%walls.count+1) parallèles ou intersection trop éloignée : refaire une mesure.") }
            corners.append(p)
        }
        guard closed, corners.count >= 3 else { return SurveyGeometry(corners: corners, lengths: [], angles: [], error: nil) }
        let n = corners.count
        for i in 0..<n { for j in (i+1)..<n where j != i+1 && !(i == 0 && j == n-1) {
            if intersects(corners[i], corners[(i+1)%n], corners[j], corners[(j+1)%n]) { return SurveyGeometry(corners: corners, lengths: [], angles: [], error: "Les murs \((i+1)%n+1) et \((j+1)%n+1) se croisent ou se superposent : vérifiez leurs mesures.") }
        } }
        let area = (0..<n).reduce(0.0) { $0 + cross(corners[$1], corners[($1+1)%n]) }
        guard abs(area) > 0.01 else { return SurveyGeometry(corners: corners, lengths: [], angles: [], error: "Contour dégénéré : les mesures ne délimitent pas une pièce.") }
        // corners[i] joins wall i to wall i+1; wall i runs from the
        // preceding intersection to corners[i].
        let lengths = (0..<n).map { simd_distance(corners[($0+n-1)%n], corners[$0]) }
        let angles = (0..<n).map { i -> Double in
            let incoming = corners[i] - corners[(i+n-1)%n], outgoing = corners[(i+1)%n] - corners[i]
            let turn = atan2(cross(incoming,outgoing), simd_dot(incoming,outgoing))
            return 180 - turn * (area > 0 ? 1 : -1) * 180 / .pi
        }
        return SurveyGeometry(corners: corners, lengths: lengths, angles: angles, error: nil)
    }
    static func planElements(_ geometry: SurveyGeometry, height: Double) -> [PlanElement] {
        let corners = geometry.corners
        guard geometry.error == nil, corners.count >= 3, geometry.lengths.count == corners.count else { return [] }
        return corners.indices.map { i in
            let start = corners[(i + corners.count - 1) % corners.count], end = corners[i]
            let delta = end - start
            return PlanElement(kind: .wall, title: "Mur \(i + 1) estimé", x: (start.x + end.x) / 2, z: (start.y + end.y) / 2, width: simd_length(delta), depth: 0.10, rotation: atan2(delta.y, delta.x), height: height)
        }
    }
    static func closure(_ first: WallLine, _ last: WallLine) -> (distance: Double, angle: Double) {
        let dot = max(-1.0, min(1.0, abs(simd_dot(first.normal,last.normal))))
        let distance1 = abs(simd_dot(last.point-first.point, first.normal))
        let distance2 = abs(simd_dot(first.point-last.point, last.normal))
        return ((distance1 + distance2)/2, acos(dot)*180 / .pi)
    }
    static func nextWallProblem(_ candidate: WallLine, after walls: [MeasuredWall], settings: SurveySettings) -> String? {
        guard let previous = walls.last else { return nil }
        let comparison = closure(previous.line, candidate)
        if comparison.distance < 0.15 && comparison.angle < 5 {
            return "Cette mesure ressemble au mur précédent. Aucun mur n’a été ajouté ; visez le mur suivant ou refaites la mesure."
        }
        guard intersection(previous.line, candidate, settings: settings) != nil else {
            return "Coin indéterminé : les deux derniers murs sont presque parallèles ou leur intersection est trop éloignée. Aucun mur n’a été ajouté ; réessayez."
        }
        return nil
    }
}
