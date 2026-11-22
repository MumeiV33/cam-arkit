import SwiftUI
import AVFoundation
import Vision
import CoreML
import UniformTypeIdentifiers
import CoreImage

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
    @Published var selectingArea = false
    @Published var hasArea = false
    @Published var monochrome = false
    @Published var contrast = false
    @Published var brighter = false
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
            HStack {
                Toggle("N&B", isOn: $state.monochrome)
                Toggle("Contraste", isOn: $state.contrast)
                Toggle("Éclaircir", isOn: $state.brighter)
            }.toggleStyle(.button).font(.caption)
            Text("Filtres cumulables : l’image affichée est aussi celle analysée.")
                .font(.caption2).foregroundStyle(.secondary)
            Text(state.modelName == nil
                 ? "Sans modèle : Vision décrit l’image, sans localiser les objets."
                 : "Modèle : \(state.modelName ?? "") · résultats expérimentaux, sans mesure.")
                .font(.caption).foregroundStyle(.secondary)
            if state.modelName == nil {
                HStack {
                    Button {
                        state.selectingArea.toggle()
                        state.controller?.setSelectingArea(state.selectingArea)
                    } label: {
                        Label(state.selectingArea ? "Annuler le tracé" : "Choisir une zone", systemImage: "crop")
                    }.buttonStyle(.bordered)
                    if state.hasArea {
                        Button("Image entière") { state.controller?.clearArea() }.buttonStyle(.bordered)
                    }
                }
                Text(state.selectingArea ? "Tracez un rectangle sur l’image avec le doigt." : (state.hasArea ? "Seule la zone bleue est analysée. Elle reste fixe à l’écran." : "Choisissez une zone pour analyser seulement une partie de l’image."))
                    .font(.caption).foregroundStyle(.secondary)
            }
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
    func updateUIViewController(_ controller: DetectionCameraController, context: Context) {
        controller.setFilters(monochrome: state.monochrome, contrast: state.contrast, brighter: state.brighter)
    }
    static func dismantleUIViewController(_ controller: DetectionCameraController, coordinator: ()) { controller.stop() }
}

private final class DetectionCameraController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    weak var state: DetectionState?
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "experiment.object-camera")
    private let overlay = CAShapeLayer()
    private let areaLayer = CAShapeLayer()
    private let filteredLayer = CALayer()
    private let imageContext = CIContext()
    private var preview: AVCaptureVideoPreviewLayer?
    private var model: VNCoreMLModel?
    private var lastFrame = Date.distantPast
    private var selectionStart = CGPoint.zero
    private var selectionRect: CGRect?
    // Accessed only on the camera queue; changes arrive from the main queue.
    private var analysisRegion = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var areaGesture: UIPanGestureRecognizer?
    private var requestedFilters = FilterOptions()
    private var activeFilters = FilterOptions() // camera queue only

    private struct FilterOptions: Equatable {
        var monochrome = false
        var contrast = false
        var brighter = false
        var enabled: Bool { monochrome || contrast || brighter }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview); self.preview = preview
        filteredLayer.contentsGravity = .resizeAspectFill
        filteredLayer.isHidden = true
        view.layer.addSublayer(filteredLayer)
        overlay.strokeColor = UIColor.systemYellow.cgColor
        overlay.fillColor = UIColor.clear.cgColor; overlay.lineWidth = 3
        view.layer.addSublayer(overlay)
        areaLayer.strokeColor = UIColor.systemBlue.cgColor
        areaLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.08).cgColor
        areaLayer.lineWidth = 3; areaLayer.lineDashPattern = [6, 4]
        view.layer.addSublayer(areaLayer)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(selectArea(_:)))
        pan.isEnabled = false; view.addGestureRecognizer(pan); areaGesture = pan
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
        super.viewDidLayoutSubviews(); preview?.frame = view.bounds; filteredLayer.frame = view.bounds; overlay.frame = view.bounds; areaLayer.frame = view.bounds
    }
    func setFilters(monochrome: Bool, contrast: Bool, brighter: Bool) {
        let options = FilterOptions(monochrome: monochrome, contrast: contrast, brighter: brighter)
        guard options != requestedFilters else { return }
        requestedFilters = options
        if !options.enabled { filteredLayer.isHidden = true; filteredLayer.contents = nil }
        queue.async { [weak self] in self?.activeFilters = options }
    }
    func setSelectingArea(_ enabled: Bool) { areaGesture?.isEnabled = enabled }
    func clearArea() {
        selectionRect = nil; areaLayer.path = nil; state?.hasArea = false
        queue.async { [weak self] in self?.analysisRegion = CGRect(x: 0, y: 0, width: 1, height: 1) }
    }
    @objc private func selectArea(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: view)
        if gesture.state == .began { selectionStart = point }
        if gesture.state == .changed || gesture.state == .ended {
            let rectangle = CGRect(x: min(selectionStart.x, point.x), y: min(selectionStart.y, point.y),
                                   width: abs(point.x - selectionStart.x), height: abs(point.y - selectionStart.y)).intersection(view.bounds)
            if !rectangle.isNull { areaLayer.path = UIBezierPath(rect: rectangle).cgPath }
            guard gesture.state == .ended else { return }
            guard !rectangle.isNull, rectangle.width >= 30, rectangle.height >= 30, let preview else {
                areaLayer.path = selectionRect.map { UIBezierPath(rect: $0).cgPath }
                state?.status = "Zone trop petite : tracez un rectangle plus grand."
                return
            }
            let metadata = preview.metadataOutputRectConverted(fromLayerRect: rectangle).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !metadata.isNull, metadata.width > 0, metadata.height > 0 else { clearArea(); return }
            let region = CGRect(x: metadata.minX, y: 1 - metadata.maxY, width: metadata.width, height: metadata.height)
            selectionRect = rectangle; state?.hasArea = true; state?.selectingArea = false; areaGesture?.isEnabled = false
            queue.async { [weak self] in self?.analysisRegion = region }
        }
        if gesture.state == .cancelled || gesture.state == .failed {
            areaLayer.path = selectionRect.map { UIBezierPath(rect: $0).cgPath }
        }
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
                    self?.clearArea(); self?.setSelectingArea(false); self?.state?.selectingArea = false
                    self?.state?.modelName = url.lastPathComponent
                    self?.state?.status = "Modèle chargé. Dirigez la caméra vers un objet."
                }
            } catch { self?.message("Modèle incompatible ou illisible : \(error.localizedDescription)") }
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let options = activeFilters
        var filteredImage: CGImage?
        if options.enabled {
            let image = CIImage(cvPixelBuffer: buffer)
            guard let filter = CIFilter(name: "CIColorControls") else { message("Filtres indisponibles."); return }
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(options.monochrome ? 0.0 : 1.0, forKey: kCIInputSaturationKey)
            filter.setValue(options.contrast ? 1.4 : 1.0, forKey: kCIInputContrastKey)
            filter.setValue(options.brighter ? 0.12 : 0.0, forKey: kCIInputBrightnessKey)
            guard let result = filter.outputImage,
                  let rendered = imageContext.createCGImage(result, from: result.extent) else { message("Impossible d’appliquer les filtres."); return }
            filteredImage = rendered
            let upright = CIImage(cgImage: rendered).oriented(.right)
            if let displayImage = imageContext.createCGImage(upright, from: upright.extent) {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.requestedFilters == options else { return }
                    self.filteredLayer.contents = displayImage; self.filteredLayer.isHidden = false
                }
            }
        }
        guard Date().timeIntervalSince(lastFrame) >= 0.6 else { return }
        lastFrame = Date()
        let request: VNImageBasedRequest
        if let model {
            let coreRequest = VNCoreMLRequest(model: model)
            coreRequest.imageCropAndScaleOption = .scaleFill
            request = coreRequest
        } else { request = VNClassifyImageRequest(); request.regionOfInterest = analysisRegion }
        do {
            let handler: VNImageRequestHandler
            if let filteredImage { handler = VNImageRequestHandler(cgImage: filteredImage, orientation: .right, options: [:]) }
            else { handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right, options: [:]) }
            try handler.perform([request])
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
