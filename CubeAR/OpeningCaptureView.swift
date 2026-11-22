import SwiftUI
import ARKit
import SceneKit
import Vision
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
                OpeningCamera(state: state).frame(minHeight: 200).clipShape(RoundedRectangle(cornerRadius: 12))
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
                    Text(state.firstPoint == nil ? "Touchez un coin du cadre sur l’image." : "Restez aussi immobile que possible et touchez le coin diagonal opposé sur le même mur.")
                        .font(.footnote)
                    Button("Effacer les points") { state.reset() }.disabled(state.firstPoint == nil)
                }
                Text("Cadres verts : rectangles candidats, pas des portes identifiées. Orientation horizontale seulement ; dimensions à vérifier au mètre et placement manuel.")
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
    private let rectangleLayer = CAShapeLayer()
    private let pointsLayer = CAShapeLayer()
    private var markedPoints: [CGPoint] = []
    private let queue = DispatchQueue(label: "opening.rectangles", qos: .userInitiated)
    private var processing = false
    private var lastAnalysis: TimeInterval = 0
    private var first: SIMD3<Float>?
    private var firstPlane: UUID?
    private var firstNormal: SIMD3<Float>?

    override func viewDidLoad() {
        super.viewDidLoad()
        scene.frame = view.bounds; scene.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scene.session.delegate = self; view.addSubview(scene)
        rectangleLayer.strokeColor = UIColor.systemGreen.cgColor; rectangleLayer.fillColor = UIColor.clear.cgColor; rectangleLayer.lineWidth = 2
        scene.layer.addSublayer(rectangleLayer)
        pointsLayer.strokeColor = UIColor.systemYellow.cgColor; pointsLayer.fillColor = UIColor.systemYellow.cgColor; pointsLayer.lineWidth = 2
        scene.layer.addSublayer(pointsLayer)
        scene.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        let configuration = ARWorldTrackingConfiguration(); configuration.planeDetection = [.vertical]
        scene.session.run(configuration)
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); rectangleLayer.frame = scene.bounds; pointsLayer.frame = scene.bounds }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); scene.session.pause() }
    func resetPoints() { first = nil; firstPlane = nil; firstNormal = nil; markedPoints.removeAll(); pointsLayer.path = nil }
    private func mark(_ point: CGPoint) {
        markedPoints.append(point)
        let path = CGMutablePath()
        for p in markedPoints { path.addEllipse(in: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)) }
        pointsLayer.path = path
    }

    private func hit(_ point: CGPoint) -> ARRaycastResult? {
        guard let query = scene.raycastQuery(from: point, allowing: .existingPlaneGeometry, alignment: .vertical) else { return nil }
        return scene.session.raycast(query).first
    }
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard state?.width == nil, let frame = scene.session.currentFrame, case .normal = frame.camera.trackingState else { state?.guidance = "Attendez un suivi normal avant de placer un point."; return }
        let screenPoint = gesture.location(in: scene)
        guard let result = hit(screenPoint), let plane = result.anchor as? ARPlaneAnchor else {
            state?.guidance = "Surface verticale non détectée à cet endroit. Bougez lentement et réessayez."; return
        }
        let t = result.worldTransform, p = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        if first == nil {
            let n = plane.transform.columns.1
            let normal = SIMD3<Float>(n.x, 0, n.z)
            guard simd_length(normal) > 0.1 else { state?.guidance = "Orientation du mur indisponible. Réessayez."; return }
            first = p; firstPlane = plane.identifier; firstNormal = simd_normalize(normal); state?.firstPoint = p; mark(screenPoint)
            state?.guidance = "Premier coin enregistré. Touchez le coin diagonal opposé."
            return
        }
        guard plane.identifier == firstPlane, let start = first, let normal = firstNormal else {
            state?.guidance = "Les deux points ne sont pas sur la même surface détectée. Effacez et recommencez."
            return
        }
        let delta = p - start
        let tangent = SIMD3<Float>(-normal.z, 0, normal.x)
        let width = Double(abs(simd_dot(delta, tangent)))
        let height = Double(abs(delta.y))
        guard width >= 0.1, height >= 0.1 else { state?.guidance = "Les points sont trop proches : choisissez deux coins opposés du cadre."; return }
        state?.secondPoint = p; state?.width = width; state?.height = height; mark(screenPoint)
        state?.guidance = "Dimensions estimées. Vérifiez-les au mètre et choisissez la position sur le plan."
    }
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard frame.timestamp - lastAnalysis > 0.5, !processing else { return }
        lastAnalysis = frame.timestamp; processing = true
        if state?.firstPoint == nil {
            if case .normal = frame.camera.trackingState, let result = hit(CGPoint(x: scene.bounds.midX, y: scene.bounds.midY)), let plane = result.anchor as? ARPlaneAnchor {
                let n = plane.transform.columns.1, c = frame.camera.transform.columns.2
                let rawNormal = SIMD2<Float>(n.x, n.z), rawForward = SIMD2<Float>(-c.x, -c.z)
                if simd_length(rawNormal) > 0.1 && simd_length(rawForward) > 0.1 {
                    var normal = simd_normalize(rawNormal); let forward = simd_normalize(rawForward)
                    if simd_dot(normal, forward) < 0 { normal = -normal }
                    let signedAngle = atan2(forward.x * normal.y - forward.y * normal.x, simd_dot(forward, normal)) * 180 / .pi
                    if abs(signedAngle) <= 8 { state?.guidance = "Orientation face au mur : environ \(Int(abs(signedAngle)))°. Touchez le premier coin." }
                    else { state?.guidance = "Pivotez lentement vers la \(signedAngle > 0 ? "droite" : "gauche") : écart horizontal ≈ \(Int(abs(signedAngle)))°." }
                }
            } else { state?.guidance = "Repérez une surface verticale et placez-vous face au mur." }
        }
        let buffer = frame.capturedImage, size = scene.bounds.size
        let displayTransform = frame.displayTransform(for: .portrait, viewportSize: size)
        queue.async { [weak self] in
            let request = VNDetectRectanglesRequest(); request.maximumObservations = 5; request.minimumConfidence = 0.6
            do {
                try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:]).perform([request])
                let rectangles = request.results ?? []
                let path = CGMutablePath()
                for rectangle in rectangles {
                    let corners = [rectangle.topLeft, rectangle.topRight, rectangle.bottomRight, rectangle.bottomLeft]
                    let projected = corners.map { point -> CGPoint in
                        let normalized = CGPoint(x: point.x, y: 1 - point.y).applying(displayTransform)
                        return CGPoint(x: normalized.x * size.width, y: normalized.y * size.height)
                    }
                    guard let first = projected.first else { continue }
                    path.move(to: first); projected.dropFirst().forEach { path.addLine(to: $0) }; path.closeSubpath()
                }
                DispatchQueue.main.async { self?.rectangleLayer.path = path; self?.processing = false }
            } catch { DispatchQueue.main.async { self?.rectangleLayer.path = nil; self?.processing = false } }
        }
    }
}
