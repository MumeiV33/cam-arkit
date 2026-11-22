import SwiftUI
import ARKit
import SceneKit
import simd

private enum OpeningChoice: String, CaseIterable, Identifiable {
    case door = "Porte", window = "Fenêtre", frenchDoor = "Porte-fenêtre"
    var id: String { rawValue }
}

@MainActor private final class OpeningCaptureState: ObservableObject {
    @Published var guidance = "Bougez lentement face au mur pour détecter une surface verticale."
    @Published var firstPoint: SIMD3<Float>?
    @Published var secondPoint: SIMD3<Float>?
    @Published var width: Double?
    @Published var height: Double?
    weak var controller: OpeningCameraController?
    func reset() { firstPoint = nil; secondPoint = nil; width = nil; height = nil; controller?.resetPoints() }
}

struct OpeningCaptureScreen: View {
    let wall: PlanElement
    let onAdd: (PlanElement) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = OpeningCaptureState()
    @State private var kind: OpeningChoice = .door
    @State private var offset: Double = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Text("Visez le mur sélectionné : l’app ne peut pas encore vérifier automatiquement sa correspondance avec le plan.")
                    .font(.footnote).foregroundStyle(.secondary)
                OpeningCamera(state: state).frame(minHeight: 200).overlay {
                    Image(systemName: "plus.circle").font(.title2.weight(.bold)).foregroundStyle(.yellow)
                        .shadow(radius: 2).allowsHitTesting(false)
                }.clipShape(RoundedRectangle(cornerRadius: 12))
                Text(state.guidance).font(.footnote.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
                Picker("Type", selection: $kind) { ForEach(OpeningChoice.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                if let width = state.width, let height = state.height {
                    Text("Mesure estimée : \(width, specifier: "%.2f") × \(height, specifier: "%.2f") m").font(.headline)
                    if width > wall.width { Text("Ouverture plus large que le mur sélectionné : vérifiez le choix du mur et recommencez.").font(.footnote).foregroundStyle(.orange) }
                    else {
                        let extent = max(0, (wall.width - width) / 2)
                        Text("Position approximative sur le mur : \(offset, specifier: "%.2f") m depuis son centre").font(.caption)
                        if extent > 0 { Slider(value: $offset, in: -extent...extent) }
                    }
                    HStack {
                        Button("Recommencer") { state.reset(); offset = 0 }
                        Spacer()
                        Button("Ajouter au plan") {
                            let limit = max(0, (wall.width - width) / 2)
                            let position = max(-limit, min(limit, offset))
                            let element = PlanElement(kind: kind == .door ? .door : .window, title: kind.rawValue,
                                x: wall.x + cos(wall.rotation) * position, z: wall.z + sin(wall.rotation) * position,
                                width: width, depth: max(0.10, wall.depth), rotation: wall.rotation, height: height)
                            onAdd(element); dismiss()
                        }.buttonStyle(.borderedProminent).disabled(width <= 0 || width > wall.width)
                    }
                } else {
                    Text(state.firstPoint == nil ? "Visez un coin du cadre avec le réticule, puis placez le point." : "Visez le coin diagonal opposé sur le même mur, puis placez le point.")
                        .font(.footnote)
                    HStack {
                        Button("Effacer les points") { state.reset() }.disabled(state.firstPoint == nil)
                        Spacer()
                        Button { state.controller?.placePoint() } label: { Label("Placer le point", systemImage: "scope") }.buttonStyle(.borderedProminent)
                    }
                }
                Text("Placez les deux coins manuellement. Les dimensions sont approximatives : vérifiez-les au mètre. La position sur le plan est réglée manuellement.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding()
                .navigationTitle("Mesurer une ouverture").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fermer") { dismiss() } } }
        }
    }
}

private struct OpeningCamera: UIViewControllerRepresentable {
    @ObservedObject var state: OpeningCaptureState
    func makeUIViewController(context: Context) -> OpeningCameraController {
        let controller = OpeningCameraController(); controller.state = state; state.controller = controller; return controller
    }
    func updateUIViewController(_ controller: OpeningCameraController, context: Context) { }
}

private final class OpeningCameraController: UIViewController, ARSessionDelegate {
    weak var state: OpeningCaptureState?
    private let scene = ARSCNView()
    private var markers: [SCNNode] = []
    private var lastAnalysis: TimeInterval = 0
    private var first: SIMD3<Float>?
    private var firstNormal: SIMD3<Float>?

    override func viewDidLoad() {
        super.viewDidLoad()
        scene.frame = view.bounds; scene.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scene.session.delegateQueue = .main
        scene.session.delegate = self; view.addSubview(scene)
        let configuration = ARWorldTrackingConfiguration(); configuration.planeDetection = [.vertical]
        scene.session.run(configuration)
    }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); scene.session.pause() }
    func resetPoints() { first = nil; firstNormal = nil; markers.forEach { $0.removeFromParentNode() }; markers.removeAll() }
    private func mark(_ point: SIMD3<Float>) {
        let sphere = SCNSphere(radius: 0.015)
        sphere.firstMaterial?.diffuse.contents = UIColor.systemYellow
        sphere.firstMaterial?.lightingModel = .constant
        let node = SCNNode(geometry: sphere)
        node.simdPosition = point
        scene.scene.rootNode.addChildNode(node)
        markers.append(node)
    }

    private func hit(_ point: CGPoint) -> ARRaycastResult? {
        guard let query = scene.raycastQuery(from: point, allowing: .existingPlaneInfinite, alignment: .vertical) else { return nil }
        return scene.session.raycast(query).first
    }
    func placePoint() {
        guard state?.width == nil, let frame = scene.session.currentFrame, case .normal = frame.camera.trackingState else { state?.guidance = "Attendez un suivi normal avant de placer un point."; return }
        let screenPoint = CGPoint(x: scene.bounds.midX, y: scene.bounds.midY)
        if first == nil {
            guard let result = hit(screenPoint), let plane = result.anchor as? ARPlaneAnchor else {
                state?.guidance = "Mur non détecté. Balayez lentement le mur, puis visez à nouveau le premier coin."
                return
            }
            let t = result.worldTransform, p = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            let n = plane.transform.columns.1
            let normal = SIMD3<Float>(n.x, 0, n.z)
            guard simd_length(normal) > 0.1 else { state?.guidance = "Orientation du mur indisponible. Réessayez."; return }
            first = p; firstNormal = simd_normalize(normal); state?.firstPoint = p; mark(p)
            state?.guidance = "Premier coin enregistré. Visez le coin diagonal opposé."
            return
        }
        guard let start = first, let normal = firstNormal,
              let query = scene.raycastQuery(from: screenPoint, allowing: .estimatedPlane, alignment: .vertical) else {
            state?.guidance = "Impossible de viser ce point. Réessayez."; return
        }
        // Project the second touch onto the first wall's infinite vertical plane.
        // Openings often contain no detected plane and ARKit can split one wall into several anchors.
        let denominator = simd_dot(query.direction, normal)
        guard abs(denominator) > 0.05 else { state?.guidance = "Placez-vous davantage face au mur puis réessayez."; return }
        let distance = simd_dot(start - query.origin, normal) / denominator
        guard distance > 0, distance < 10 else { state?.guidance = "Point trop éloigné ou hors du mur. Rapprochez-vous et réessayez."; return }
        let p = query.origin + distance * query.direction
        let delta = p - start
        let tangent = SIMD3<Float>(-normal.z, 0, normal.x)
        let width = Double(abs(simd_dot(delta, tangent)))
        let height = Double(abs(delta.y))
        guard width >= 0.1, height >= 0.1 else { state?.guidance = "Les points sont trop proches : choisissez deux coins opposés du cadre."; return }
        state?.secondPoint = p; state?.width = width; state?.height = height; mark(p)
        state?.guidance = "Dimensions estimées. Vérifiez-les au mètre et choisissez la position sur le plan."
    }
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard frame.timestamp - lastAnalysis > 0.5 else { return }
        lastAnalysis = frame.timestamp
        if state?.firstPoint == nil {
            if case .normal = frame.camera.trackingState, let result = hit(CGPoint(x: scene.bounds.midX, y: scene.bounds.midY)), let plane = result.anchor as? ARPlaneAnchor {
                let n = plane.transform.columns.1, c = frame.camera.transform.columns.2
                let rawNormal = SIMD2<Float>(n.x, n.z), rawForward = SIMD2<Float>(-c.x, -c.z)
                if simd_length(rawNormal) > 0.1 && simd_length(rawForward) > 0.1 {
                    var normal = simd_normalize(rawNormal); let forward = simd_normalize(rawForward)
                    if simd_dot(normal, forward) < 0 { normal = -normal }
                    let signedAngle = atan2(forward.x * normal.y - forward.y * normal.x, simd_dot(forward, normal)) * 180 / .pi
                    if abs(signedAngle) <= 8 { state?.guidance = "Orientation face au mur : environ \(Int(abs(signedAngle)))°. Visez le premier coin." }
                    else { state?.guidance = "Pivotez lentement vers la \(signedAngle > 0 ? "droite" : "gauche") : écart horizontal ≈ \(Int(abs(signedAngle)))°." }
                }
            } else { state?.guidance = "Repérez une surface verticale et placez-vous face au mur." }
        }
    }
}
