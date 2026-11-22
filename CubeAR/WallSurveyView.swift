import SwiftUI
import ARKit
import SceneKit

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
    let direction: SurveyDirection
    let session = ARSession()
    var settings = SurveySettings()
    private var samples: [(TimeInterval, simd_float4x4)] = []
    private var startedAt: TimeInterval = 0
    private var timeout: Timer?
    private var lastNormalFrame: TimeInterval = 0

    init(direction: SurveyDirection) { self.direction = direction; super.init(); session.delegate = self }
    func start() { guard ARWorldTrackingConfiguration.isSupported else { status = "ARKit indisponible sur cet appareil."; return }; session.run(ARWorldTrackingConfiguration()) }
    func stop() { cancel(); session.pause() }
    func beginCapture() {
        guard !capturing else { return }
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
    func undo() { guard !capturing, !walls.isEmpty else { return }; walls.removeLast(); closureResult = nil; closureAccepted = false; checkingClosure = false; status = "Dernière mesure retirée." }
    func prepareClosure() { guard walls.count >= 3, !capturing else { return }; checkingClosure = true; closureResult = nil; closureAccepted = false; status = "Retournez au mur 1 pour contrôler la boucle. Cette mesure ne crée pas de nouveau mur." }
    func resumeWalls() { checkingClosure = false; closureAccepted = false; closureResult = nil; status = "Mesurez le mur suivant." }
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let state = frame.camera.trackingState
        let transform = frame.camera.transform
        let timestamp = frame.timestamp
        Task { @MainActor in self.receive(state: state, transform: transform, timestamp: timestamp) }
    }
    private func receive(state: ARCamera.TrackingState, transform: simd_float4x4, timestamp: TimeInterval) {
        guard case .normal = state else { tracking = "Limité — bougez lentement, améliorez la lumière"; samples.removeAll(); stable = false; return }
        tracking = "Normal"; lastNormalFrame = ProcessInfo.processInfo.systemUptime
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
        if checkingClosure, let firstWall = walls.first {
            let result = WallGeometry.closure(firstWall.line, line)
            let geometry = WallGeometry.geometry(walls, closed: true, settings: settings)
            let points = geometry.corners
            let signedArea = points.indices.reduce(0.0) { sum, i in sum + WallGeometry.cross(points[i], points[(i + 1) % points.count]) }
            // In the displayed X/Z plan, positive signed area is clockwise.
            let directionMatches = points.count >= 3 && ((signedArea > 0) == (direction == .clockwise))
            let good = result.distance <= settings.goodClosureDistance && result.angle <= settings.goodClosureAngle && geometry.error == nil && directionMatches
            let uncertain = result.distance <= settings.uncertainClosureDistance && result.angle <= settings.uncertainClosureAngle
            closureAccepted = good
            let directionWarning = directionMatches ? "" : " · sens du contour différent du sens choisi"
            closureResult = String(format: "%@ · écart %.0f cm · orientation %.1f°%@%@", good ? "Boucle cohérente" : (uncertain ? "Boucle incertaine" : "Boucle incohérente"), result.distance * 100, result.angle, geometry.error.map { " · " + $0 } ?? "", directionWarning)
            if good { walls[0].observations.append(observation) }
            status = good ? "Contrôle terminé. Les mesures restent approximatives." : "Vérifiez les murs et recommencez le contrôle."
            UINotificationFeedbackGenerator().notificationOccurred(good ? .success : .warning)
        } else {
            walls.append(MeasuredWall(observations: [observation], line: line)); closureAccepted = false; closureResult = nil
            status = "Mur \(walls.count) enregistré. Passez au mur suivant."
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
    private func finishFailure(_ text: String) { cancel(); status = text; UINotificationFeedbackGenerator().notificationOccurred(.error) }
    var geometry: SurveyGeometry { WallGeometry.geometry(walls, closed: closureAccepted, settings: settings) }
}

struct WallSurveyStartView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var direction: SurveyDirection = .clockwise
    @State private var showSurvey = false
    var body: some View {
        Form {
            Section("Nouvelle mesure de pièce") {
                Text("Faites le tour de la pièce et plaquez l’écran contre chaque mur. Les coins sont estimés par intersection.")
                Picker("Sens vu du dessus", selection: $direction) { ForEach(SurveyDirection.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Label(ARWorldTrackingConfiguration.isSupported ? "ARKit compatible" : "ARKit indisponible", systemImage: ARWorldTrackingConfiguration.isSupported ? "checkmark.circle" : "xmark.circle")
                Button("Commencer") { showSurvey = true }.disabled(!ARWorldTrackingConfiguration.isSupported)
            }
            Section("Précision") { Text("Prototype expérimental : l’écran peut ne pas être parfaitement plaqué. La dérive ARKit et la coque influencent les mesures ; vérifiez au mètre.") }
        }.navigationTitle("Relevé par contact")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fermer") { dismiss() } } }
            .fullScreenCover(isPresented: $showSurvey) { WallSurveyScreen(direction: direction) }
    }
}

struct WallSurveyScreen: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: FloorPlanStore
    @StateObject private var model: WallSurveyModel
    @State private var wallHeight = 2.4
    @State private var planName = "Pièce relevée"
    @State private var showing3D = false
    @State private var savedMessage = false
    init(direction: SurveyDirection) { _model = StateObject(wrappedValue: WallSurveyModel(direction: direction)) }
    var body: some View {
        NavigationStack {
            ScrollView { VStack(alignment: .leading, spacing: 12) {
                WallSurveyCamera(session: model.session).frame(height: 190).clipShape(RoundedRectangle(cornerRadius: 12))
                Text("\(model.walls.count) mur(s) · sens \(model.direction.rawValue.lowercased())").font(.headline)
                Text(model.checkingClosure ? "Contrôle : premier mur" : "Prochain mur : \(model.walls.count + 1)")
                Text("Suivi : \(model.tracking) · Stabilité : \(model.stable ? "stable" : "en attente")").font(.footnote)
                Text(model.status).font(.callout)
                if model.capturing { Text("\(model.remaining) s maximum — écran contre le mur").font(.headline); Button("Annuler la capture") { model.cancel() } }
                else {
                    if !model.closureAccepted {
                        Button(model.checkingClosure ? "Contrôler le mur 1" : "Enregistrer un mur") { model.beginCapture() }.buttonStyle(.borderedProminent)
                    }
                    HStack {
                        Button("Refaire le dernier mur") { model.undo() }.disabled(model.walls.isEmpty)
                        Spacer()
                        if model.checkingClosure { Button("Ajouter un mur") { model.resumeWalls() } }
                        else { Button("Terminer le parcours") { model.prepareClosure() }.disabled(model.walls.count < 3) }
                    }
                }
                if let closure = model.closureResult { Text(closure).foregroundStyle(model.closureAccepted ? .green : .orange) }
                if let error = model.geometry.error { Text(error).foregroundStyle(.orange) }
                SurveyPlanView(geometry: model.geometry).frame(height: 230).background(Color(uiColor: .secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 12))
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
                Stepper("Décalage caméra-écran estimé : \(model.offsetCentimeters, specifier: "%.1f") cm", value: $model.offsetCentimeters, in: 0...3, step: 0.1).disabled(!model.walls.isEmpty || model.capturing)
                Text("Valeur indicative, coque comprise ; elle n’est pas calibrée automatiquement. Les hauteurs et angles inclinés ne sont pas mesurés.").font(.caption).foregroundStyle(.secondary)
                ForEach(model.walls.indices, id: \.self) { index in
                    Text("Mur \(index+1) · \(model.walls[index].observations.count) observation(s) · suivi \(model.walls[index].observations.first?.trackingQuality ?? "inconnu")").font(.footnote)
                }
            }.padding() }
            .navigationTitle("Mesure des murs").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fermer") { model.stop(); dismiss() } } }
            .sheet(isPresented: $showing3D) { Plan3DView(plan: FloorPlan(elements: WallGeometry.planElements(model.geometry, height: wallHeight))) }
            .onAppear { model.start() }.onDisappear { model.stop() }
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
    var body: some View { GeometryReader { proxy in
        let points = geometry.corners
        let minX = points.map(\.x).min() ?? -1, maxX = points.map(\.x).max() ?? 1
        let minY = points.map(\.y).min() ?? -1, maxY = points.map(\.y).max() ?? 1
        let scale = min((proxy.size.width-30)/CGFloat(max(maxX-minX, 0.5)), (proxy.size.height-30)/CGFloat(max(maxY-minY, 0.5)))
        Canvas { context, _ in
            guard points.count >= 2 else { return }
            func convert(_ p: SIMD2<Double>) -> CGPoint { CGPoint(x: 15 + CGFloat(p.x-minX)*scale, y: 15 + CGFloat(p.y-minY)*scale) }
            var path = Path(); path.move(to: convert(points[0])); for p in points.dropFirst() { path.addLine(to: convert(p)) }
            if !geometry.lengths.isEmpty { path.closeSubpath() }
            context.stroke(path, with: .color(geometry.error == nil ? .blue : .orange), lineWidth: 3)
            for p in points { let q = convert(p); context.fill(Path(ellipseIn: CGRect(x: q.x-4, y: q.y-4, width: 8, height: 8)), with: .color(.red)) }
        }
    } }
}
