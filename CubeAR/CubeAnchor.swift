import ARKit

/// Une ancre persistante : sa matrice stocke à la fois position et orientation du cube.
final class CubeAnchor: ARAnchor {
    static let typeName = "cube-anchor"

    override class var supportsSecureCoding: Bool { true }

    required init(anchor: ARAnchor) {
        super.init(anchor: anchor)
    }

    override init(transform: simd_float4x4) {
        super.init(transform: transform)
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }
}
