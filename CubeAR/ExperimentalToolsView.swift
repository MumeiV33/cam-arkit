import SwiftUI
import AVFoundation
import Vision
import CoreML
import UniformTypeIdentifiers

struct ExperimentalToolsView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Ces essais utilisent la caméra sans LiDAR et ne modifient pas vos plans.")
                }
                Section("Caméra et intelligence artificielle") {
                    NavigationLink {
                        ObjectDetectionExperiment()
                    } label: {
                        Label("Reconnaissance d’objets", systemImage: "viewfinder")
                    }
                    Text("Vision peut décrire l’image. Un modèle Core ML de détection compatible est nécessaire pour encadrer des objets, portes ou fenêtres.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Outils expérimentaux")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fermer") { dismiss() } } }
        }
    }
}

@MainActor private final class DetectionState: ObservableObject {
    @Published var status = "Démarrage de la caméra…"
    @Published var modelName: String?
    weak var controller: DetectionCameraController?
}

private struct ObjectDetectionExperiment: View {
    @StateObject private var state = DetectionState()
    @State private var importing = false

    var body: some View {
        VStack(spacing: 10) {
            DetectionCamera(state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(state.status).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
            Text(state.modelName == nil
                 ? "Sans modèle : Vision décrit l’image, sans localiser les objets."
                 : "Modèle : \(state.modelName ?? "") · résultats expérimentaux, sans mesure.")
                .font(.caption).foregroundStyle(.secondary)
            Button { importing = true } label: { Label("Importer un modèle Core ML", systemImage: "square.and.arrow.down") }
                .buttonStyle(.bordered)
            Text("Fichier .mlmodel de détection compatible Vision. Pour les portes et fenêtres, il doit avoir été entraîné à les reconnaître.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding().navigationTitle("Reconnaissance").navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "mlmodel") ?? .data]) { result in
            switch result {
            case .success(let url): state.controller?.loadModel(url)
            case .failure(let error): state.status = "Import impossible : \(error.localizedDescription)"
            }
        }
    }
}

private struct DetectionCamera: UIViewControllerRepresentable {
    @ObservedObject var state: DetectionState
    func makeUIViewController(context: Context) -> DetectionCameraController {
        let controller = DetectionCameraController()
        controller.state = state; state.controller = controller
        return controller
    }
    func updateUIViewController(_ controller: DetectionCameraController, context: Context) { }
    static func dismantleUIViewController(_ controller: DetectionCameraController, coordinator: ()) { controller.stop() }
}

private final class DetectionCameraController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    weak var state: DetectionState?
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "experiment.object-camera")
    private let overlay = CAShapeLayer()
    private var preview: AVCaptureVideoPreviewLayer?
    private var model: VNCoreMLModel?
    private var lastFrame = Date.distantPast

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview); self.preview = preview
        overlay.strokeColor = UIColor.systemYellow.cgColor
        overlay.fillColor = UIColor.clear.cgColor; overlay.lineWidth = 3
        view.layer.addSublayer(overlay)
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                if allowed { self?.start() } else { self?.message("Autorisez la caméra dans les réglages de l’iPhone.") }
            }
        default: message("Autorisez la caméra dans les réglages de l’iPhone.")
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews(); preview?.frame = view.bounds; overlay.frame = view.bounds
    }
    private func message(_ text: String) { DispatchQueue.main.async { [weak self] in self?.state?.status = text } }
    private func start() {
        queue.async { [weak self] in
            guard let self, let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) else {
                self?.message("Caméra indisponible."); return
            }
            let output = AVCaptureVideoDataOutput()
            guard self.session.canAddOutput(output) else { self.message("Flux caméra indisponible."); return }
            self.session.beginConfiguration(); self.session.sessionPreset = .medium
            self.session.addInput(input); self.session.addOutput(output)
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: self.queue)
            self.session.commitConfiguration(); self.session.startRunning()
            self.message("Analyse en cours : dirigez la caméra vers un objet.")
        }
    }
    func stop() { queue.async { [session] in session.stopRunning() } }
    func loadModel(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        message("Chargement du modèle…")
        queue.async { [weak self] in
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let compiled = try MLModel.compileModel(at: url)
                let model = try VNCoreMLModel(for: MLModel(contentsOf: compiled))
                self?.model = model
                DispatchQueue.main.async { [weak self] in
                    self?.state?.modelName = url.lastPathComponent
                    self?.state?.status = "Modèle chargé. Dirigez la caméra vers un objet."
                }
            } catch { self?.message("Modèle incompatible ou illisible : \(error.localizedDescription)") }
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard Date().timeIntervalSince(lastFrame) >= 0.6, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrame = Date()
        let request: VNImageBasedRequest
        if let model {
            let coreRequest = VNCoreMLRequest(model: model)
            coreRequest.imageCropAndScaleOption = .scaleFill
            request = coreRequest
        } else { request = VNClassifyImageRequest() }
        do {
            try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right, options: [:]).perform([request])
            if let objects = request.results as? [VNRecognizedObjectObservation] {
                let found = objects.filter { $0.confidence >= 0.4 }
                let text = found.prefix(4).compactMap { $0.labels.first }.map { "\($0.identifier) \(Int($0.confidence * 100)) %" }.joined(separator: " · ")
                DispatchQueue.main.async { [weak self] in
                    guard let self, let preview = self.preview else { return }
                    let path = CGMutablePath()
                    for object in found {
                        let box = object.boundingBox
                        let rect = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
                        path.addRect(preview.layerRectConverted(fromMetadataOutputRect: rect))
                    }
                    self.overlay.path = path
                    self.state?.status = text.isEmpty ? "Aucun objet reconnu avec assez de confiance." : text
                }
            } else if let classifications = request.results as? [VNClassificationObservation] {
                let text = classifications.prefix(3).map { "\($0.identifier) \(Int($0.confidence * 100)) %" }.joined(separator: " · ")
                DispatchQueue.main.async { [weak self] in self?.overlay.path = nil; self?.state?.status = text.isEmpty ? "Aucune classification." : text }
            } else {
                message("Ce modèle ne fournit pas de détections ou classifications compatibles Vision.")
            }
        } catch { message("Analyse impossible : \(error.localizedDescription)") }
    }
}
