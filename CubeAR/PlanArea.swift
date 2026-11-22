import Foundation
import simd

enum PlanArea {
    /// Area is computed only when wall endpoints form one unambiguous closed loop.
    /// Tolerance accounts for small gaps in scans, not missing walls or rooms.
    static func closedContour(walls: [PlanElement], tolerance: Double = 0.08) -> [SIMD2<Double>]? {
        guard walls.count >= 3, tolerance > 0 else { return nil }
        let segments = walls.map { wall -> (SIMD2<Double>, SIMD2<Double>) in
            let center = SIMD2(wall.x, wall.z)
            let direction = SIMD2(cos(wall.rotation), sin(wall.rotation)) * (wall.width / 2)
            return (center - direction, center + direction)
        }
        guard segments.allSatisfy({ simd_distance($0.0, $0.1) > 0.01 }) else { return nil }
        var points = [segments[0].0, segments[0].1]
        var remaining = Array(segments.dropFirst())
        while !remaining.isEmpty {
            guard let current = points.last else { return nil }
            let matches = remaining.enumerated().compactMap { index, segment -> (Int, SIMD2<Double>)? in
                let startMatch = simd_distance(current, segment.0) <= tolerance
                let endMatch = simd_distance(current, segment.1) <= tolerance
                guard startMatch != endMatch else { return nil }
                return (startMatch || endMatch) ? (index, startMatch ? segment.1 : segment.0) : nil
            }
            guard matches.count == 1, let match = matches.first else { return nil }
            points.append(match.1); remaining.remove(at: match.0)
        }
        guard let end = points.last, simd_distance(end, points[0]) <= tolerance else { return nil }
        points.removeLast()
        let n = points.count
        guard n >= 3 else { return nil }
        for i in 0..<n { for j in (i+1)..<n where j != i+1 && !(i == 0 && j == n-1) {
            if WallGeometry.intersects(points[i], points[(i+1)%n], points[j], points[(j+1)%n]) { return nil }
        } }
        return points
    }
    static func area(walls: [PlanElement]) -> Double? {
        guard let points = closedContour(walls: walls) else { return nil }
        let sum = points.indices.reduce(0.0) { total, i in total + WallGeometry.cross(points[i], points[(i+1)%points.count]) }
        let result = abs(sum) / 2
        return result > 0.01 ? result : nil
    }
}
