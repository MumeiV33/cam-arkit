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
            let height: CGFloat = isWall ? 2.4 : (item.kind == .door || item.kind == .window ? 2.0 : 0.7)
            let box = SCNBox(width: CGFloat(item.width), height: height, length: CGFloat(item.depth), chamferRadius: isWall ? 0 : 0.04)
            let material = SCNMaterial(); material.diffuse.contents = color(for: item.kind); box.materials = [material]
            let node = SCNNode(geometry: box); node.position = SCNVector3(Float(item.x), Float(height / 2), Float(item.z)); node.eulerAngles.y = Float(-item.rotation); scene.rootNode.addChildNode(node)
        }
        let camera = SCNNode(); camera.camera = SCNCamera(); camera.position = SCNVector3(0, 6, 7); let look = SCNLookAtConstraint(target: scene.rootNode); look.isGimbalLockEnabled = true; camera.constraints = [look]; scene.rootNode.addChildNode(camera)
        return scene
    }
    private func color(for kind: PlanElementKind) -> UIColor { switch kind { case .wall: .darkGray; case .door: .systemOrange; case .window: .systemCyan; case .fixedFurniture: .gray; case .movableFurniture: .systemTeal } }
}
