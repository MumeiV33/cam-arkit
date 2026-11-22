import SwiftUI
import SceneKit

struct Plan3DView: View {
    let plan: FloorPlan
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack { Plan3DContainer(plan: plan).ignoresSafeArea().navigationTitle("Vue 3D").toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fermer") { dismiss() } } } }
    }
}

struct Plan3DContainer: UIViewRepresentable {
    let plan: FloorPlan
    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(); view.scene = makeScene(); view.allowsCameraControl = true; view.backgroundColor = .systemBackground; view.autoenablesDefaultLighting = true
        return view
    }
    func updateUIView(_ uiView: SCNView, context: Context) { uiView.scene = makeScene() }
    private func makeScene() -> SCNScene {
        let scene = SCNScene()
        let floor = SCNNode(geometry: SCNFloor()); floor.geometry?.firstMaterial?.diffuse.contents = UIColor.secondarySystemBackground; scene.rootNode.addChildNode(floor)
        for item in plan.elements {
            let isWall = item.kind == .wall
            let height = CGFloat(item.measuredHeight)
            let box = SCNBox(width: CGFloat(item.width), height: height, length: CGFloat(item.depth), chamferRadius: isWall ? 0 : 0.04)
            let material = SCNMaterial(); material.diffuse.contents = color(for: item.kind); box.materials = [material]
            let node = SCNNode(geometry: box); node.position = SCNVector3(Float(item.x), Float(height / 2), Float(item.z)); node.eulerAngles.y = Float(-item.rotation); scene.rootNode.addChildNode(node)
        }
        let xs = plan.elements.map(\.x), zs = plan.elements.map(\.z)
        let centerX = ((xs.min() ?? 0) + (xs.max() ?? 0)) / 2
        let centerZ = ((zs.min() ?? 0) + (zs.max() ?? 0)) / 2
        let span = max(4.0, (xs.max() ?? 0) - (xs.min() ?? 0), (zs.max() ?? 0) - (zs.min() ?? 0))
        let target = SCNNode(); target.position = SCNVector3(Float(centerX), 0.8, Float(centerZ)); scene.rootNode.addChildNode(target)
        let camera = SCNNode(); camera.camera = SCNCamera(); camera.position = SCNVector3(Float(centerX), Float(span * 1.2), Float(centerZ + span * 1.3)); let look = SCNLookAtConstraint(target: target); look.isGimbalLockEnabled = true; camera.constraints = [look]; scene.rootNode.addChildNode(camera)
        return scene
    }
    private func color(for kind: PlanElementKind) -> UIColor { switch kind { case .wall: .darkGray; case .door: .systemOrange; case .window: .systemCyan; case .fixedFurniture: .gray; case .movableFurniture: .systemTeal } }
}
