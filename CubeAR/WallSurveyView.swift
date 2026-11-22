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
        if let firstWall = walls.first {
            let result = WallGeometry.closure(firstWall.line, line)
            let geometry = WallGeometry.geometry(walls, closed: true, settings: settings)
            let points = geometry.corners
            let signedArea = points.indices.reduce(0.0) { sum, i in sum + WallGeometry.cross(points[i], points[(i + 1) % points.count]) }
            // In the displayed X/Z plan, positive signed area is clockwise.
            let directionMatches = points.count >= 3 && ((signedArea > 0) == (direction == .clockwise))
            let good = result.distance <= settings.goodClosureDistance && result.angle <= settings.goodClosureAngle && geometry.error == nil && directionMatches
            let uncertain = result.distance <= settings.uncertainClosureDistance && result.angle <= settings.uncertainClosureAngle
            closureAccepted = good
            let wallGood = result.distance <= settings.goodClosureDistance && result.angle <= settings.goodClosureAngle
            closureResult = String(format: "Mur 1 : %@ · écart %.0f cm · orientation %.1f°. Contour : %@", wallGood ? "cohérent" : (uncertain ? "incertain" : "incohérent"), result.distance * 100, result.angle, geometry.error ?? (directionMatches ? "cohérent" : "sens différent de celui choisi"))
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
                Text("\(model.walls.count) mur(s) · sens \(model.direction.rawValue.lowercased())").font(.headline)
                Text("Mode : \(model.captureMode.rawValue)").font(.footnote)
                Text(model.checkingClosure ? "Contrôle : premier mur" : "Prochain mur : \(model.walls.count + 1)")
                if model.pendingObservation != nil { Text("Mur \(model.walls.count + 1) : première prise sauvegardée. Faites la seconde sur le même mur.").font(.footnote).foregroundStyle(.orange) }
                Text("Suivi : \(model.tracking) · Stabilité : \(model.stable ? "stable" : "en attente")").font(.footnote)
                Text(model.status).font(.callout)
                if model.capturing { Text("\(model.remaining) s maximum — écran contre le mur").font(.headline); Button("Annuler la capture") { model.cancel() } }
                else if !model.readOnly {
                    if !model.closureAccepted {
                        Button(model.checkingClosure ? "Contrôler le mur 1" : (model.captureMode == .twoPoints ? (model.pendingObservation == nil ? "Première prise du mur" : "Deuxième prise du mur") : "Enregistrer un mur")) { model.beginCapture() }.buttonStyle(.borderedProminent).disabled(model.relocalizing)
                    }
                    if model.pendingObservation != nil {
                        Button("Passer la deuxième prise pour ce mur") { model.finishWallWithFirstPoint() }
                            .disabled(model.relocalizing)
                        Text("Le mur sera estimé avec une seule prise ; les murs suivants resteront en mode deux points.").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(model.pendingObservation == nil ? "Refaire le dernier mur" : "Retirer la première prise") { model.undo() }.disabled((model.walls.isEmpty && model.pendingObservation == nil) || model.relocalizing)
                        Spacer()
                        if model.checkingClosure { Button("Ajouter un mur") { model.resumeWalls() } }
                        else { Button("Terminer le parcours") {
                            saveDraft()
                            guard drafts.error == nil else { return }
                            if model.hasWorldMap { model.stop(); dismiss() }
                            else { confirmFinishWithoutMap = true }
                        }.disabled((model.walls.isEmpty && model.pendingObservation == nil) || model.mapSaving) }
                    }
                    if !model.checkingClosure && !model.closureAccepted && model.walls.count >= 3 && model.pendingObservation == nil {
                        Button("Fermer le contour : contrôler le mur 1") { model.prepareClosure() }
                        Text("Ne rajoutez pas le mur 1 : mesurez-le une nouvelle fois avec ce bouton pour contrôler et fermer le contour.").font(.caption).foregroundStyle(.secondary)
                    }
                    if model.lastWallMayDuplicateFirst && model.pendingObservation == nil {
                        Button("Vérifier le dernier mur : possible doublon du mur 1") { confirmRemoveDuplicate = true }.foregroundStyle(.orange)
                    }
                }
                if !model.readOnly {
                    Text(model.mapStatus).font(.footnote).foregroundStyle(.secondary)
                    Button("Actualiser la carte pour reprendre plus tard") { model.saveWorldMap() }
                        .disabled((model.walls.isEmpty && model.pendingObservation == nil) || model.mapSaving || model.relocalizing)
                    Button(model.referenceImageData == nil ? "Prendre une photo de repère (facultatif)" : "Remplacer la photo de repère") { model.captureReferenceImage() }
                        .disabled(model.capturing || model.relocalizing)
                    Text("Prenez cette vue téléphone en main, dans une zone reconnaissable. La photo reste sur cet iPhone.").font(.caption).foregroundStyle(.secondary)
                }
                if let error = drafts.error { Text(error).foregroundStyle(.red) }
                if let closure = model.closureResult { Text(closure).foregroundStyle(model.closureAccepted ? .green : .orange) }
                if let error = model.geometry.error { Text(error).foregroundStyle(.orange) }
                SurveyPlanView(geometry: model.geometry, walls: model.walls, cameraPosition: model.readOnly || model.relocalizing ? nil : model.cameraPosition, cameraDirection: model.cameraDirection, settings: model.settings).frame(height: 260).background(Color(uiColor: .secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 12))
                Text("Les numéros identifient les murs. La flèche bleue indique la position et la direction approximatives de la caméra lorsque le suivi est normal.").font(.caption).foregroundStyle(.secondary)
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
    let cameraPosition: SIMD2<Double>?
    let cameraDirection: SIMD2<Double>?
    let settings: SurveySettings
    var body: some View { GeometryReader { proxy in
        let points = geometry.corners
        let displayPoints = points + walls.map { $0.line.point } + (cameraPosition.map { [$0] } ?? [])
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
            let center = walls.isEmpty ? SIMD2<Double>(0, 0) : walls.map { $0.line.point }.reduce(SIMD2<Double>(0, 0), +) / Double(walls.count)
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
                    let q = convert(wall.line.point)
                    context.fill(Path(ellipseIn: CGRect(x: q.x-3, y: q.y-3, width: 6, height: 6)), with: .color(.orange))
                }
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
