import SwiftUI
import ARKit
import SceneKit
import CoreImage
import ImageIO

@MainActor final class WallSurveyModel: NSObject, ObservableObject, ARSessionDelegate {
    @Published var walls: [MeasuredWall] = []
    @Published var status = "Déplacez lentement le téléphone pour initialiser le suivi."
    @Published var tracking = "Initialisation"
    @Published var stable = false
    @Published var remaining = 0
    @Published var capturing = false
    @Published var checkingClosure = false
    @Published var closureResult: String?
    @Published var closureAccepted = false
    @Published var offsetCentimeters = 1.0
    @Published var relocalizing = false
    @Published var mapStatus = "Carte AR en attente"
    @Published var mapSaving = false
    @Published var cameraPosition: SIMD2<Double>?
    @Published var cameraDirection: SIMD2<Double>?
    @Published var pendingObservation: WallObservation?
    @Published var possibleFirstWall = false
    private var firstWallCandidate: (WallLine, [WallObservation])?
    let direction: SurveyDirection
    let captureMode: WallCaptureMode
    let session = ARSession()
    var settings = SurveySettings()
    let draftID: UUID
    let createdAt: Date
    @Published private(set) var readOnly: Bool
    private var savedMapData: Data?
    @Published private(set) var referenceImageData: Data?
    private var storedDraft: WallSurveyDraft?
    private var sawRelocalizing = false
    private var sessionInterrupted = false
    private var lastMapRequest: TimeInterval = 0
    var hasWorldMap: Bool { savedMapData != nil }
    var persist: (() -> Void)?
    private var samples: [(TimeInterval, simd_float4x4)] = []
    private var startedAt: TimeInterval = 0
    private var timeout: Timer?
    private var lastNormalFrame: TimeInterval = 0
    private var lastPositionUpdate: TimeInterval = 0

    init(direction: SurveyDirection, mode: WallCaptureMode = .single, draft: WallSurveyDraft? = nil, resume: Bool = false) {
        self.direction = direction
        self.captureMode = draft.flatMap { $0.captureMode }.flatMap(WallCaptureMode.init(rawValue:)) ?? mode
        self.draftID = draft?.id ?? UUID(); self.createdAt = draft?.createdAt ?? Date()
        self.readOnly = draft != nil
        self.savedMapData = draft?.worldMapData
        self.referenceImageData = draft?.referenceImageData
        self.storedDraft = resume ? draft : nil
        super.init()
        if let draft {
            walls = draft.walls.map { $0.wall() }; offsetCentimeters = draft.offsetCentimeters
            closureAccepted = draft.closureAccepted; closureResult = draft.closureResult
            pendingObservation = draft.pendingObservation?.observation()
            status = "Brouillon restauré en consultation. Les mesures sont conservées."
        }
        session.delegate = self
    }
    func snapshot() -> WallSurveyDraft {
        WallSurveyDraft(id: draftID, createdAt: createdAt, updatedAt: Date(), direction: direction.rawValue,
                        offsetCentimeters: offsetCentimeters, walls: walls.map(SavedSurveyWall.init),
                        closureAccepted: closureAccepted, closureResult: closureResult, worldMapData: savedMapData, referenceImageData: referenceImageData, captureMode: captureMode.rawValue, pendingObservation: pendingObservation.map(SavedWallObservation.init))
    }
    func start() {
        guard ARWorldTrackingConfiguration.isSupported else { status = "ARKit indisponible sur cet appareil."; return }
        if readOnly && storedDraft == nil { return }
        let config = ARWorldTrackingConfiguration()
        if readOnly {
            guard let data = savedMapData, let map = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
                status = "Aucune carte AR exploitable pour ce brouillon : consultation uniquement."
                return
            }
            config.initialWorldMap = map; relocalizing = true; sawRelocalizing = false
            status = "Retournez dans la pièce et visez lentement les zones déjà observées."
        }
        session.run(config)
    }
    func captureReferenceImage() {
        guard !readOnly, !relocalizing, !capturing, let frame = session.currentFrame else { return }
        let image = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: min(1, 640 / image.extent.width), y: min(1, 640 / image.extent.width)))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent),
              let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.65) else {
            status = "Impossible d’enregistrer la photo de repère."; return
        }
        referenceImageData = data
        status = "Photo de repère enregistrée localement."
        persist?()
    }
    func stop() { cancel(); session.pause() }
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }
    func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor in
            self.sessionInterrupted = true; self.relocalizing = true; self.sawRelocalizing = false
            self.cancel(); self.status = "Session interrompue. Revenez dans la pièce pour retrouver le repère."
        }
    }
    func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor in self.status = "Reprise : visez lentement les zones déjà observées." }
    }
    func saveWorldMap() {
        guard !readOnly, !relocalizing, !sessionInterrupted, !mapSaving, !walls.isEmpty || pendingObservation != nil else { return }
        guard let frame = session.currentFrame else { mapStatus = "Caméra non disponible : carte non sauvegardée."; return }
        guard case .normal = frame.camera.trackingState else { mapStatus = "Suivi limité : carte non actualisée."; return }
        guard frame.worldMappingStatus == .mapped || frame.worldMappingStatus == .extending else {
            mapStatus = "Explorez davantage la pièce : carte encore insuffisante pour reprendre."
            return
        }
        mapSaving = true; mapStatus = "Sauvegarde de la carte AR…"
        session.getCurrentWorldMap { [weak self] map, error in
            Task { @MainActor in
                guard let self else { return }
                self.mapSaving = false
                guard !self.relocalizing, !self.sessionInterrupted else { self.mapStatus = "Session interrompue : dernière carte conservée."; return }
                guard let map else { self.mapStatus = "Carte AR non sauvegardée : \(error?.localizedDescription ?? "réessayez")"; return }
                do {
                    self.savedMapData = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
                    self.mapStatus = "Carte AR prête à être sauvegardée."
                    self.persist?()
                } catch { self.mapStatus = "Carte AR non sauvegardée : \(error.localizedDescription)" }
            }
        }
    }
    func beginCapture() {
        guard !capturing, !readOnly, !relocalizing, !sessionInterrupted else { return }
        samples.removeAll(); stable = false; capturing = true; remaining = 10
        startedAt = ProcessInfo.processInfo.systemUptime
        status = "Retournez le téléphone et plaquez l’écran contre le mur."
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        timeout = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    private func tick() {
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        remaining = max(0, Int(ceil(10 - elapsed)))
        if elapsed >= 10 { finishFailure("Capture échouée : suivi ou stabilité insuffisants. Réessayez.") }
    }
    func cancel() { timeout?.invalidate(); timeout = nil; capturing = false; samples.removeAll(); stable = false }
    func undo() { guard !readOnly, !capturing else { return }; if pendingObservation != nil { pendingObservation = nil; status = "Première prise retirée." } else if !walls.isEmpty { walls.removeLast(); status = "Dernier mur retiré." } else { return }; closureResult = nil; closureAccepted = false; checkingClosure = false; persist?() }
    func finishWallWithFirstPoint() {
        guard !readOnly, !capturing, !relocalizing, !sessionInterrupted, let first = pendingObservation else { return }
        guard let line = WallGeometry.line(transform: first.cameraTransform, offset: Float(offsetCentimeters / 100)) else {
            status = "Première prise invalide : retirez-la et recommencez."
            return
        }
        if let problem = WallGeometry.nextWallProblem(line, after: walls, settings: settings) {
            status = problem
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        submitWall(line: line, observations: [first])
    }
    func prepareClosure() { guard walls.count >= 3, !capturing, pendingObservation == nil else { return }; checkingClosure = true; closureResult = nil; closureAccepted = false; status = "Retournez au mur 1 pour contrôler la boucle. Une seule prise suffit pour ce contrôle." }
    func resumeWalls() { checkingClosure = false; closureAccepted = false; closureResult = nil; status = "Mesurez le mur suivant." }
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let state = frame.camera.trackingState
        let transform = frame.camera.transform
        let timestamp = frame.timestamp
        let mapping = frame.worldMappingStatus
        Task { @MainActor in self.receive(state: state, transform: transform, timestamp: timestamp, mapping: mapping) }
    }
    private func receive(state: ARCamera.TrackingState, transform: simd_float4x4, timestamp: TimeInterval, mapping: ARFrame.WorldMappingStatus) {
        if case .limited(.relocalizing) = state { sawRelocalizing = true; relocalizing = true }
        guard case .normal = state else { tracking = "Limité — bougez lentement, améliorez la lumière"; cameraPosition = nil; cameraDirection = nil; samples.removeAll(); stable = false; return }
        if relocalizing {
            guard sawRelocalizing else { return }
            relocalizing = false; readOnly = false; sessionInterrupted = false
            status = "Pièce reconnue : vous pouvez reprendre les mesures. Vérifiez la cohérence au mètre."
        }
        guard !readOnly, !sessionInterrupted else { return }
        tracking = "Normal"; lastNormalFrame = ProcessInfo.processInfo.systemUptime
        if timestamp - lastPositionUpdate >= 0.2 {
            cameraPosition = SIMD2(Double(transform.columns.3.x), Double(transform.columns.3.z))
            let forward = SIMD2<Double>(-Double(transform.columns.2.x), -Double(transform.columns.2.z))
            cameraDirection = simd_length(forward) > 0.1 ? simd_normalize(forward) : nil
            lastPositionUpdate = timestamp
        }
        if (!walls.isEmpty || pendingObservation != nil) && !capturing && !mapSaving && timestamp - lastMapRequest > 8 && (mapping == .mapped || mapping == .extending) {
            lastMapRequest = timestamp; saveWorldMap()
        }
        guard capturing else { return }
        samples.append((timestamp, transform)); samples.removeAll { timestamp - $0.0 > 1.1 }
        guard let first = samples.first, samples.count >= 8, timestamp - first.0 >= 0.9 else { stable = false; return }
        let origin = SIMD3<Float>(first.1.columns.3.x, first.1.columns.3.y, first.1.columns.3.z)
        let base = simd_quatf(first.1)
        let maxDistance = samples.map { simd_distance(origin, SIMD3<Float>($0.1.columns.3.x, $0.1.columns.3.y, $0.1.columns.3.z)) }.max() ?? 1
        let maxAngle = samples.map { 2 * acos(min(1, abs(simd_dot(base.vector, simd_quatf($0.1).vector)))) }.max() ?? 1
        stable = maxDistance <= settings.maxMotion && maxAngle <= settings.maxRotation
        // Require time to turn the phone over before considering a stable window.
        guard stable, ProcessInfo.processInfo.systemUptime - startedAt >= 3 else { return }
        let representative = samples[samples.count / 2]
        guard let line = WallGeometry.line(transform: representative.1, offset: Float(offsetCentimeters / 100)) else { finishFailure("Téléphone trop incliné : plaquez l’écran verticalement et réessayez."); return }
        let observation = WallObservation(timestamp: representative.0, cameraTransform: representative.1, trackingQuality: "normal", stabilityScore: maxDistance)
        cancel()
        if checkingClosure {
            checkFirstWall(line: line, observations: [observation])
        } else {
            acceptWallObservation(observation, line: line)
        }
    }
    private func checkFirstWall(line: WallLine, observations: [WallObservation]) {
        if let result = WallGeometry.assessClosure(walls: walls, check: line, direction: direction, settings: settings) {
            let good = result.accepted
            let uncertain = result.distance <= settings.uncertainClosureDistance && result.angle <= settings.uncertainClosureAngle
            closureAccepted = good
            let warning = result.directionWarning ? " Sens différent de celui choisi : vérifiez le parcours." : ""
            closureResult = String(format: "Mur 1 : %@ · écart %.0f cm · orientation %.1f°. Contour : %@%@", result.wallConsistent ? "cohérent" : (uncertain ? "incertain" : "incohérent"), result.distance * 100, result.angle, result.contourError ?? "géométriquement fermé", warning)
            // Keep the control observations even when the closure is uncertain.
            walls[0].observations.append(contentsOf: observations)
            status = good ? "Contrôle terminé. Les mesures restent approximatives." : "Vérifiez les murs et recommencez le contrôle."
            persist?()
            saveWorldMap()
            UINotificationFeedbackGenerator().notificationOccurred(good ? .success : .warning)
        }
    }
    private func acceptWallObservation(_ observation: WallObservation, line: WallLine) {
            var estimatedLine = line
            var observations = [observation]
            if captureMode == .twoPoints {
                guard let first = pendingObservation else {
                    pendingObservation = observation
                    status = "Première prise enregistrée. Déplacez-vous d’au moins 30 cm sur le même mur pour la seconde."
                    persist?(); saveWorldMap(); UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    return
                }
                guard let firstLine = WallGeometry.line(transform: first.cameraTransform, offset: Float(offsetCentimeters / 100)) else {
                    status = "Première prise invalide : retirez-la et recommencez."; return
                }
                let estimate = WallGeometry.twoPointWall(firstLine, line)
                guard let combined = estimate.line else { status = estimate.error ?? "Deuxième prise invalide."; UINotificationFeedbackGenerator().notificationOccurred(.error); return }
                estimatedLine = combined; observations = [first, observation]
            }
            if let problem = WallGeometry.nextWallProblem(estimatedLine, after: walls, settings: settings) {
                status = problem
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                return
            }
            submitWall(line: estimatedLine, observations: observations)
    }
    private func submitWall(line: WallLine, observations: [WallObservation]) {
            if walls.count >= 3, let first = walls.first {
                let comparison = WallGeometry.closure(first.line, line)
                if comparison.distance <= settings.goodClosureDistance && comparison.angle <= settings.goodClosureAngle {
                    firstWallCandidate = (line, observations); possibleFirstWall = true
                    status = "Cette prise ressemble au mur 1 : choisissez comment l’utiliser."
                    return
                }
            }
            addWall(line: line, observations: observations)
    }
    private func addWall(line: WallLine, observations: [WallObservation]) {
            walls.append(MeasuredWall(observations: observations, line: line)); pendingObservation = nil; closureAccepted = false; closureResult = nil
            status = "Mur \(walls.count) enregistré. Passez au mur suivant."
            persist?()
            saveWorldMap()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    func resolveFirstWallCandidate(useAsControl: Bool) {
        guard let candidate = firstWallCandidate else { return }
        firstWallCandidate = nil; possibleFirstWall = false
        if useAsControl {
            pendingObservation = nil; checkingClosure = true
            checkFirstWall(line: candidate.0, observations: candidate.1)
        } else { addWall(line: candidate.0, observations: candidate.1) }
    }
    var lastWallMayDuplicateFirst: Bool {
        guard walls.count >= 4, let first = walls.first, let last = walls.last else { return false }
        let comparison = WallGeometry.closure(first.line, last.line)
        return comparison.distance <= settings.goodClosureDistance && comparison.angle <= settings.goodClosureAngle
    }
    private func finishFailure(_ text: String) { cancel(); status = text; UINotificationFeedbackGenerator().notificationOccurred(.error) }
    var geometry: SurveyGeometry { WallGeometry.geometry(walls, closed: closureAccepted, settings: settings) }
    var pendingLine: WallLine? {
        guard let observation = pendingObservation else { return nil }
        return WallGeometry.line(transform: observation.cameraTransform, offset: Float(offsetCentimeters / 100))
    }
}

struct WallSurveyStartView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var drafts: WallSurveyDraftStore
    @State private var direction: SurveyDirection = .clockwise
    @State private var mode: WallCaptureMode = .single
    @State private var showSurvey = false
    @State private var selectedDraft: WallSurveyDraft?
    @State private var draftAction: SurveyDraftAction?
    @State private var showDraftChoices = false
    var body: some View {
        Form {
            Section("Nouvelle mesure de pièce") {
                Text("Faites le tour de la pièce et plaquez l’écran contre chaque mur. Les coins sont estimés par intersection.")
                Picker("Sens vu du dessus", selection: $direction) { ForEach(SurveyDirection.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Picker("Mesure par mur", selection: $mode) { ForEach(WallCaptureMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                if mode == .twoPoints { Text("Deux prises sur la même face du mur, espacées d’au moins 30 cm. Le mur est ajouté après la seconde prise si elles sont cohérentes.").font(.footnote).foregroundStyle(.secondary) }
                Label(ARWorldTrackingConfiguration.isSupported ? "ARKit compatible" : "ARKit indisponible", systemImage: ARWorldTrackingConfiguration.isSupported ? "checkmark.circle" : "xmark.circle")
                Button("Commencer") { showSurvey = true }.disabled(!ARWorldTrackingConfiguration.isSupported)
            }
            Section("Précision") { Text("Prototype expérimental : l’écran peut ne pas être parfaitement plaqué. La dérive ARKit et la coque influencent les mesures ; vérifiez au mètre.") }
            Section("Relevés sauvegardés") {
                if drafts.drafts.isEmpty { Text("Aucun relevé enregistré.").foregroundStyle(.secondary) }
                ForEach(drafts.drafts.sorted { $0.updatedAt > $1.updatedAt }) { draft in
                    Button { selectedDraft = draft; showDraftChoices = true } label: {
                        VStack(alignment: .leading) {
                            Text("\(draft.closureAccepted ? "Relevé contrôlé" : "Brouillon") · \(draft.walls.count) mur(s)")
                            Text(draft.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let error = drafts.error { Text(error).foregroundStyle(.red) }
            }
        }.navigationTitle("Relevé par contact")
            .confirmationDialog("Que faire avec ce relevé ?", isPresented: $showDraftChoices, titleVisibility: .visible, presenting: selectedDraft) { draft in
                Button("Consulter le brouillon") { draftAction = SurveyDraftAction(draft: draft, resume: false) }
                if draft.worldMapData != nil {
                    Button("Reprendre avec ARKit") { draftAction = SurveyDraftAction(draft: draft, resume: true) }
                }
                Button("Annuler", role: .cancel) { }
            } message: { draft in Text(draft.worldMapData == nil ? "Ce relevé n’a pas de carte AR : seule la consultation est possible." : "Revenez dans la même pièce pour retrouver le repère enregistré.") }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fermer") { dismiss() } } }
            .fullScreenCover(isPresented: $showSurvey) { WallSurveyScreen(direction: direction, mode: mode) }
            .fullScreenCover(item: $draftAction) { action in
                WallSurveyScreen(direction: SurveyDirection(rawValue: action.draft.direction) ?? .clockwise, draft: action.draft, resume: action.resume)
            }
    }
}

private struct SurveyDraftAction: Identifiable {
    let id = UUID()
    let draft: WallSurveyDraft
    let resume: Bool
}

struct WallSurveyScreen: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: FloorPlanStore
    @EnvironmentObject private var drafts: WallSurveyDraftStore
    @StateObject private var model: WallSurveyModel
    @State private var wallHeight = 2.4
    @State private var planName = "Pièce relevée"
    @State private var showing3D = false
    @State private var savedMessage = false
    @State private var confirmFinishWithoutMap = false
    @State private var confirmRemoveDuplicate = false
    init(direction: SurveyDirection, mode: WallCaptureMode = .single, draft: WallSurveyDraft? = nil, resume: Bool = false) { _model = StateObject(wrappedValue: WallSurveyModel(direction: direction, mode: mode, draft: draft, resume: resume)) }
    private func saveDraft() {
        guard !model.walls.isEmpty || model.pendingObservation != nil || model.referenceImageData != nil || drafts.drafts.contains(where: { $0.id == model.draftID }) else { return }
        if !drafts.save(model.snapshot()) { model.status = drafts.error ?? "Le brouillon n’a pas pu être sauvegardé." }
    }
    var body: some View {
        NavigationStack {
            ScrollView { VStack(alignment: .leading, spacing: 12) {
                if !model.readOnly || model.relocalizing { WallSurveyCamera(session: model.session).frame(height: 190).clipShape(RoundedRectangle(cornerRadius: 12)) }
                if model.readOnly {
                    Text(model.relocalizing ? "Revenez dans la pièce et visez les zones déjà observées. Les mesures seront possibles après reconnaissance." : "Consultation du relevé enregistré.").font(.footnote).foregroundStyle(.orange)
                    if model.relocalizing, let data = model.referenceImageData, let image = UIImage(data: data) {
                        Text("Vue de repère facultative").font(.caption)
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 150).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                HStack {
                    Label("\(model.walls.count) mur(s)", systemImage: "square.split.2x2").font(.headline)
                    Spacer()
                    Label(model.tracking == "Normal" ? "Suivi actif" : "Suivi limité", systemImage: model.tracking == "Normal" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(model.tracking == "Normal" ? .green : .orange)
                }
                Text(model.checkingClosure ? "Contrôle du mur 1" : "Mur \(model.walls.count + 1) · \(model.captureMode.rawValue)").font(.subheadline.weight(.semibold))
                Text(model.status).font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                if model.capturing {
                    HStack { Label("\(model.remaining) s · écran contre le mur", systemImage: "timer").font(.headline); Spacer(); Button("Annuler") { model.cancel() }.buttonStyle(.bordered) }
                }
                else if !model.readOnly {
                    if !model.closureAccepted {
                        Button { model.beginCapture() } label: {
                            Label(model.checkingClosure ? "Mesurer le mur 1" : (model.captureMode == .twoPoints ? (model.pendingObservation == nil ? "Mesurer le premier point" : "Mesurer le deuxième point") : "Mesurer ce mur"), systemImage: model.checkingClosure ? "checkmark.circle" : "viewfinder")
                                .frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.relocalizing)
                    }
                    if model.pendingObservation != nil {
                        Button { model.finishWallWithFirstPoint() } label: { Label("Utiliser un seul point pour ce mur", systemImage: "forward.end") }
                            .buttonStyle(.bordered).tint(.orange).disabled(model.relocalizing)
                    }
                    HStack {
                        if model.checkingClosure {
                            Button { model.resumeWalls() } label: { Label("Revenir aux murs", systemImage: "arrow.uturn.backward") }.buttonStyle(.bordered)
                        } else if !model.closureAccepted && model.walls.count >= 3 && model.pendingObservation == nil {
                            Button { model.prepareClosure() } label: { Label("Vérifier le mur 1", systemImage: "checkmark.circle") }.buttonStyle(.bordered).tint(.green)
                        }
                        Spacer()
                        Menu {
                            Button { model.undo() } label: { Label(model.pendingObservation == nil ? "Retirer le dernier mur" : "Retirer le premier point", systemImage: "arrow.uturn.backward") }
                                .disabled((model.walls.isEmpty && model.pendingObservation == nil) || model.relocalizing)
                            if model.lastWallMayDuplicateFirst && model.pendingObservation == nil {
                                Button { confirmRemoveDuplicate = true } label: { Label("Vérifier le possible doublon", systemImage: "exclamationmark.triangle") }
                            }
                            Button { model.saveWorldMap() } label: { Label("Actualiser la carte AR", systemImage: "map") }
                                .disabled((model.walls.isEmpty && model.pendingObservation == nil) || model.mapSaving || model.relocalizing)
                            Button { model.captureReferenceImage() } label: { Label(model.referenceImageData == nil ? "Photo de repère" : "Remplacer la photo de repère", systemImage: "camera") }.disabled(model.relocalizing)
                            Button { saveDraft(); guard drafts.error == nil else { return }; if model.hasWorldMap { model.stop(); dismiss() } else { confirmFinishWithoutMap = true } } label: { Label("Enregistrer et fermer", systemImage: "square.and.arrow.down") }
                                .disabled((model.walls.isEmpty && model.pendingObservation == nil) || model.mapSaving)
                        } label: { Label("Options", systemImage: "ellipsis.circle") }.buttonStyle(.bordered)
                    }
                    if model.walls.count >= 3 && !model.closureAccepted { Text("Après le dernier mur, utilisez Vérifier le mur 1. Ne l’ajoutez pas comme nouveau mur.").font(.caption).foregroundStyle(.secondary) }
                    Text(model.mapStatus).font(.caption).foregroundStyle(.secondary)
                }
                if let error = drafts.error { Text(error).foregroundStyle(.red) }
                if let closure = model.closureResult { Text(closure).foregroundStyle(model.closureAccepted ? .green : .orange) }
                if let error = model.geometry.error { Text(error).foregroundStyle(.orange) }
                SurveyPlanView(geometry: model.geometry, walls: model.walls, pendingLine: model.pendingLine, cameraPosition: model.readOnly || model.relocalizing ? nil : model.cameraPosition, cameraDirection: model.cameraDirection, settings: model.settings).frame(height: 260).background(Color(uiColor: .secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 12))
                Text("Pointillés : direction estimée, pas une longueur mesurée. La flèche bleue indique approximativement la caméra.").font(.caption).foregroundStyle(.secondary)
                if !model.walls.isEmpty && model.geometry.corners.count < 2 {
                    Text("Les points indiquent les positions de mesure. Les longueurs apparaissent quand les intersections sont calculables.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(model.geometry.lengths.enumerated()), id: \.offset) { index, length in Text("Mur \(index+1) : ≈ \(length, specifier: "%.2f") m · angle avec mur \((index+1)%model.walls.count+1) : ≈ \(model.geometry.angles[index], specifier: "%.0f")°") }
                if model.geometry.lengths.isEmpty, model.geometry.corners.count >= 2 {
                    let points = model.geometry.corners
                    Text("Dernier segment estimé : ≈ \(simd_distance(points[points.count-2], points[points.count-1]), specifier: "%.2f") m")
                }
                if model.closureAccepted {
                    Divider()
                    Text("Construire la pièce").font(.headline)
                    Text("Les longueurs et angles proviennent du relevé. La hauteur n’est pas mesurée : renseignez une valeur pour la vue 3D.").font(.footnote)
                    Stepper("Hauteur supposée : \(wallHeight, specifier: "%.2f") m", value: $wallHeight, in: 1.5...6, step: 0.1)
                    TextField("Nom du nouveau plan", text: $planName).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Voir la pièce en 3D") { showing3D = true }.buttonStyle(.bordered)
                        Button("Enregistrer le plan") {
                            store.saveSurveyPlan(named: planName.trimmingCharacters(in: .whitespacesAndNewlines), elements: WallGeometry.planElements(model.geometry, height: wallHeight))
                            savedMessage = true
                        }.buttonStyle(.borderedProminent)
                    }
                    if savedMessage { Text("Plan enregistré dans le lieu sélectionné. Fermez le relevé pour le consulter.").font(.footnote).foregroundStyle(.green) }
                }
                Stepper("Décalage caméra-écran estimé : \(model.offsetCentimeters, specifier: "%.1f") cm", value: $model.offsetCentimeters, in: 0...3, step: 0.1).disabled(!model.walls.isEmpty || model.pendingObservation != nil || model.capturing)
                Text("Valeur indicative, coque comprise ; elle n’est pas calibrée automatiquement. Les hauteurs et angles inclinés ne sont pas mesurés.").font(.caption).foregroundStyle(.secondary)
                ForEach(model.walls.indices, id: \.self) { index in
                    Text("Mur \(index+1) · \(model.walls[index].observations.count) observation(s) · suivi \(model.walls[index].observations.first?.trackingQuality ?? "inconnu")").font(.footnote)
                }
            }.padding() }
            .navigationTitle("Mesure des murs").navigationBarTitleDisplayMode(.inline)
            .alert("Brouillon sauvegardé sans carte AR", isPresented: $confirmFinishWithoutMap) {
                Button("Explorer encore", role: .cancel) { }
                Button("Fermer quand même") { model.stop(); dismiss() }
            } message: { Text("Les murs sont sauvegardés, mais la reprise avec ARKit ne sera pas disponible sans carte. Bougez lentement dans la pièce puis actualisez la carte.") }
            .alert("Cette mesure correspond-elle au mur 1 ?", isPresented: $model.possibleFirstWall) {
                Button("Utiliser pour contrôler le mur 1") { model.resolveFirstWallCandidate(useAsControl: true) }
                Button("Garder comme nouveau mur") { model.resolveFirstWallCandidate(useAsControl: false) }
            } message: { Text("Les positions et orientations sont proches. Si vous êtes revenu sur le premier mur, utilisez cette prise comme contrôle : aucun mur supplémentaire ne sera créé.") }
            .alert("Retirer le dernier mur ?", isPresented: $confirmRemoveDuplicate) {
                Button("Retirer le dernier mur", role: .destructive) { model.undo() }
                Button("Conserver", role: .cancel) { }
            } message: { Text("Le dernier mur ressemble au mur 1. Retirez-le uniquement si vous l’avez enregistré une deuxième fois pour fermer le contour. Les autres murs seront conservés.") }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fermer") {
                if !model.readOnly { saveDraft(); guard drafts.error == nil else { return } }
                model.stop(); dismiss()
            }.disabled(model.mapSaving) } }
            .sheet(isPresented: $showing3D) { Plan3DView(plan: FloorPlan(elements: WallGeometry.planElements(model.geometry, height: wallHeight))) }
            .onAppear {
                model.persist = { saveDraft() }
                model.start()
            }.onDisappear { model.stop() }
        }
    }
}

struct WallSurveyCamera: UIViewRepresentable {
    let session: ARSession
    func makeUIView(context: Context) -> ARSCNView { let view = ARSCNView(); view.session = session; return view }
    func updateUIView(_ view: ARSCNView, context: Context) { }
}

struct SurveyPlanView: View {
    let geometry: SurveyGeometry
    let walls: [MeasuredWall]
    let pendingLine: WallLine?
    let cameraPosition: SIMD2<Double>?
    let cameraDirection: SIMD2<Double>?
    let settings: SurveySettings
    var body: some View { GeometryReader { proxy in
        let points = geometry.corners
        let guideLines = walls.map(\.line) + (pendingLine.map { [$0] } ?? [])
        let guideExtents = guideLines.flatMap { [$0.point - $0.direction * 0.35, $0.point + $0.direction * 0.35] }
        let displayPoints = points + guideExtents + (cameraPosition.map { [$0] } ?? [])
        let minX = displayPoints.map(\.x).min() ?? -1, maxX = displayPoints.map(\.x).max() ?? 1
        let minY = displayPoints.map(\.y).min() ?? -1, maxY = displayPoints.map(\.y).max() ?? 1
        let scale = min(max(1, proxy.size.width-64)/CGFloat(max(maxX-minX, 0.5)), max(1, proxy.size.height-64)/CGFloat(max(maxY-minY, 0.5)))
        Canvas { context, _ in
            func convert(_ p: SIMD2<Double>) -> CGPoint { CGPoint(x: 32 + CGFloat(p.x-minX)*scale, y: 32 + CGFloat(p.y-minY)*scale) }
            if points.count >= 2 {
                var path = Path(); path.move(to: convert(points[0])); for p in points.dropFirst() { path.addLine(to: convert(p)) }
                if !geometry.lengths.isEmpty { path.closeSubpath() }
                context.stroke(path, with: .color(geometry.error == nil ? .blue : .orange), lineWidth: 3)
            }
            func drawGuide(_ line: WallLine, color: Color) {
                var guide = Path(); guide.move(to: convert(line.point - line.direction * 0.35)); guide.addLine(to: convert(line.point + line.direction * 0.35))
                context.stroke(guide, with: .color(color), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                let q = convert(line.point)
                context.fill(Path(ellipseIn: CGRect(x: q.x-4, y: q.y-4, width: 8, height: 8)), with: .color(color))
            }
            let center = walls.isEmpty ? (pendingLine?.point ?? SIMD2<Double>(0, 0)) : walls.map { $0.line.point }.reduce(SIMD2<Double>(0, 0), +) / Double(walls.count)
            for (i, wall) in walls.enumerated() {
                let before = i > 0 ? WallGeometry.intersection(walls[i-1].line, wall.line, settings: settings) : (geometry.lengths.isEmpty ? nil : points.last)
                let after = i+1 < walls.count ? WallGeometry.intersection(wall.line, walls[i+1].line, settings: settings) : (geometry.lengths.isEmpty ? nil : points.last)
                let middle = before.flatMap { start in after.map { (start + $0) / 2 } } ?? wall.line.point
                var outward = middle - center
                if simd_length(outward) < 0.01 { outward = wall.line.normal }
                outward = simd_normalize(outward)
                let position = convert(middle)
                let labelPoint = CGPoint(x: position.x + CGFloat(outward.x)*18, y: position.y + CGFloat(outward.y)*18)
                context.draw(Text("M\(i+1)").font(.caption.bold()).foregroundColor(.primary), at: labelPoint)
                if before == nil || after == nil {
                    drawGuide(wall.line, color: .orange)
                }
            }
            if let pendingLine {
                drawGuide(pendingLine, color: .orange)
                let point = convert(pendingLine.point)
                context.draw(Text("M\(walls.count+1) · 1/2").font(.caption.bold()).foregroundColor(.orange), at: CGPoint(x: point.x, y: point.y-16))
            }
            for p in points { let q = convert(p); context.fill(Path(ellipseIn: CGRect(x: q.x-3, y: q.y-3, width: 6, height: 6)), with: .color(.red)) }
            if let position = cameraPosition {
                let p = convert(position)
                context.fill(Path(ellipseIn: CGRect(x: p.x-5, y: p.y-5, width: 10, height: 10)), with: .color(.blue))
                if let direction = cameraDirection {
                    let end = CGPoint(x: p.x + CGFloat(direction.x)*22, y: p.y + CGFloat(direction.y)*22)
                    var arrow = Path(); arrow.move(to: p); arrow.addLine(to: end)
                    context.stroke(arrow, with: .color(.blue), lineWidth: 3)
                }
            }
        }
    } }
}
