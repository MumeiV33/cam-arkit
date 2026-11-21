import SwiftUI
import ARKit
import Vision
import SceneKit

enum CameraExperiment: Int, CaseIterable, Identifiable {
    case contours = 1, points, plan
    var id: Int { rawValue }
    var title: String { switch self { case .contours: return "1 · Contours"; case .points: return "2 · Repères AR"; case .plan: return "3 · Plan guidé" } }
    var detail: String { switch self {
    case .contours: return "Visualise les contours détectés en direct. Les meubles et ombres produisent aussi des traits."
    case .points: return "Vise le sol et place des repères qui restent dans la pièce. Déplace-toi pour améliorer le suivi."
    case .plan: return "Place dans l’ordre au moins trois coins au sol, puis crée un plan approximatif. Vérifie les mesures."
    } }
}

struct CameraExperimentsView: View {
    @State private var selection: CameraExperiment?
    var body: some View {
        NavigationStack {
            List {
                Section { Text("Trois essais indépendants utilisant la caméra et ARKit. Les résultats sont expérimentaux et ne remplacent pas un relevé au mètre.") }
                Section("Prototypes") {
                    ForEach(CameraExperiment.allCases) { experiment in
                        Button { selection = experiment } label: {
                            VStack(alignment: .leading, spacing: 5) { Text(experiment.title).font(.headline); Text(experiment.detail).font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                }
            }.navigationTitle("Sans LiDAR")
                .fullScreenCover(item: $selection) { CameraExperimentScreen(experiment: $0) }
        }
    }
}

struct CameraExperimentScreen: View {
    let experiment: CameraExperiment
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: FloorPlanStore
    @StateObject private var state = ExperimentState()
    @State private var confirmReplace = false
    var body: some View {
        ZStack(alignment: .bottom) {
            ExperimentCamera(experiment: experiment, state: state).ignoresSafeArea()
            if experiment != .contours {
                Image(systemName: "plus").font(.title.bold()).foregroundStyle(.yellow)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
            }
            VStack(spacing: 12) {
                HStack { Button("Fermer") { dismiss() }; Spacer(); Text(experiment.title).bold() }.padding()
                Text(state.status).font(.footnote).padding(10).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                Spacer()
                if experiment != .contours {
                    Text("Repères : \(state.points.count)").font(.headline)
                    HStack {
                        Button("Annuler dernier") { state.controller?.undo() }.disabled(state.points.isEmpty)
                        Spacer()
                        Button("Placer un point") { state.controller?.placePoint() }.buttonStyle(.borderedProminent)
                    }
                    if experiment == .plan {
                        Button("Créer le plan") { confirmReplace = true }.buttonStyle(.borderedProminent).disabled(state.points.count < 3)
                    }
                }
            }.foregroundStyle(.white).padding().background(alignment: .bottom) { LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom).ignoresSafeArea() }
        }
        .alert("Remplacer le plan actuel ?", isPresented: $confirmReplace) {
            Button("Remplacer", role: .destructive) { store.replaceWithGuidedPoints(state.points); dismiss() }
            Button("Annuler", role: .cancel) { }
        } message: { Text("Le contour remplacera le contenu du plan sélectionné. Les autres plans restent intacts.") }
    }
}

@MainActor final class ExperimentState: ObservableObject {
    @Published var status = "Bougez lentement pour détecter le sol."
    @Published var points: [SIMD3<Float>] = []
    weak var controller: ExperimentCameraController?
}

struct ExperimentCamera: UIViewControllerRepresentable {
    let experiment: CameraExperiment
    @ObservedObject var state: ExperimentState
    func makeUIViewController(context: Context) -> ExperimentCameraController {
        let controller = ExperimentCameraController()
        controller.experiment = experiment; controller.state = state; state.controller = controller
        return controller
    }
    func updateUIViewController(_ controller: ExperimentCameraController, context: Context) { }
}

final class ExperimentCameraController: UIViewController, ARSessionDelegate {
    var experiment: CameraExperiment = .contours
    weak var state: ExperimentState?
    private let arView = ARSCNView()
    private let overlay = CAShapeLayer()
    private var anchors: [ARAnchor] = []
    private var processing = false
    private var lastFrameTime: TimeInterval = 0
    private let processingQueue = DispatchQueue(label: "camera.contours", qos: .userInitiated)

    override func viewDidLoad() {
        super.viewDidLoad()
        arView.frame = view.bounds; arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        arView.automaticallyUpdatesLighting = true; arView.session.delegate = self
        view.addSubview(arView)
        overlay.strokeColor = UIColor.systemGreen.cgColor; overlay.fillColor = UIColor.clear.cgColor; overlay.lineWidth = 1.2
        arView.layer.addSublayer(overlay)
        let configuration = ARWorldTrackingConfiguration(); configuration.planeDetection = [.horizontal, .vertical]
        arView.session.run(configuration)
        state?.status = experiment == .contours ? "Contours en vert : marchez lentement autour de la pièce." : "Visez un angle au sol au centre de l’écran."
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); overlay.frame = arView.bounds }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); arView.session.pause() }

    func placePoint() {
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        guard let query = arView.raycastQuery(from: center, allowing: .existingPlaneGeometry, alignment: .horizontal), let result = arView.session.raycast(query).first else {
            state?.status = "Sol non détecté : éclairez-le et bougez lentement l’iPhone."; return
        }
        let t = result.worldTransform
        let point = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let anchor = ARAnchor(transform: t); anchors.append(anchor); arView.session.add(anchor: anchor)
        let marker = SCNNode(geometry: SCNSphere(radius: 0.025)); marker.geometry?.firstMaterial?.diffuse.contents = UIColor.systemYellow
        marker.simdPosition = point; arView.scene.rootNode.addChildNode(marker); marker.name = anchor.identifier.uuidString
        state?.points.append(point); state?.status = "Repère placé. Visez le prochain angle au sol."
    }
    func undo() {
        guard let anchor = anchors.popLast() else { return }
        arView.session.remove(anchor: anchor); arView.scene.rootNode.childNode(withName: anchor.identifier.uuidString, recursively: false)?.removeFromParent()
        if state?.points.isEmpty == false { state?.points.removeLast() }
    }
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard experiment == .contours, !processing, frame.timestamp - lastFrameTime > 0.5 else { return }
        processing = true; lastFrameTime = frame.timestamp
        let pixelBuffer = frame.capturedImage
        let size = arView.bounds.size
        let transform = frame.displayTransform(for: .portrait, viewportSize: size)
        processingQueue.async { [weak self] in
            let request = VNDetectContoursRequest(); request.maximumImageDimension = 512
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
            do {
                try handler.perform([request])
                let contours = request.results?.first?.normalizedPath
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let contours {
                        var flip = CGAffineTransform(translationX: 0, y: 1).scaledBy(x: 1, y: -1)
                        let path = contours.copy(using: &flip)
                        var display = transform.concatenating(CGAffineTransform(scaleX: size.width, y: size.height))
                        self.overlay.path = path?.copy(using: &display)
                    } else { self.overlay.path = nil }
                    self.processing = false
                }
            } catch { DispatchQueue.main.async { self?.processing = false; self?.state?.status = "Analyse des contours indisponible." } }
        }
    }
}
