import SwiftUI

struct FloorPlanEditorView: View {
    @EnvironmentObject private var store: FloorPlanStore
    @State private var selectedID: UUID?
    @State private var adding: PlanElementKind?
    @State private var showLibrary = false
    @State private var show3D = false
    @State private var showCaptureChoice = false
    @State private var showContactCapture = false
    @State private var confirmLidarReplacement = false
    @State private var overlays = PlanOverlayOptions()
    @State private var editing = false
    @State private var initialPositions: [UUID: CGPoint] = [:]
    @State private var moveHistory: [PlanMove] = []
    @State private var confirmReset = false
    private func setEditing(_ enabled: Bool) {
        editing = enabled; adding = nil; moveHistory.removeAll()
        initialPositions = enabled ? Dictionary(uniqueKeysWithValues: store.plan.elements.map { ($0.id, CGPoint(x: CGFloat($0.x), y: CGFloat($0.z))) }) : [:]
    }
    private func move(_ id: UUID, by delta: CGPoint) {
        guard editing, let index = store.plan.elements.firstIndex(where: { $0.id == id }), delta != .zero else { return }
        let element = store.plan.elements[index]
        moveHistory.append(PlanMove(id: id, position: CGPoint(x: CGFloat(element.x), y: CGFloat(element.z))))
        store.plan.elements[index].x += Double(delta.x); store.plan.elements[index].z += Double(delta.y); store.changed()
    }
    private func undoMove() {
        guard let previous = moveHistory.popLast(), let index = store.plan.elements.firstIndex(where: { $0.id == previous.id }) else { return }
        store.plan.elements[index].x = Double(previous.position.x); store.plan.elements[index].z = Double(previous.position.y); store.changed()
    }
    private func resetMoves() {
        for index in store.plan.elements.indices {
            guard let position = initialPositions[store.plan.elements[index].id] else { continue }
            store.plan.elements[index].x = Double(position.x); store.plan.elements[index].z = Double(position.y)
        }
        moveHistory.removeAll(); store.changed()
    }
    var body: some View {
        NavigationStack { VStack(spacing: 0) {
            if let adding { Text("Touchez le plan pour ajouter : \(adding.title)").font(.footnote.weight(.semibold)).padding(8).frame(maxWidth: .infinity).background(.orange.opacity(0.25)) }
            InteractivePlanView(elements: $store.plan.elements, selectedID: $selectedID, adding: $adding, overlays: overlays, planID: store.selectedPlanID, editing: editing, onMoveElement: move) { store.changed() }
                .clipped().background(Color(uiColor: .secondarySystemBackground))
            HStack {
                Toggle("Éditer", isOn: Binding(get: { editing }, set: { setEditing($0) })).toggleStyle(.switch)
                if editing {
                    Button { undoMove() } label: { Label("Annuler", systemImage: "arrow.uturn.backward") }.disabled(moveHistory.isEmpty)
                    Button { confirmReset = true } label: { Label("Réinitialiser", systemImage: "arrow.counterclockwise") }.disabled(moveHistory.isEmpty)
                }
            }.font(.footnote).padding(.horizontal).padding(.vertical, 6)
            if let id = selectedID, let index = store.plan.elements.firstIndex(where: { $0.id == id }) { ElementInspector(element: $store.plan.elements[index], editing: editing) { store.delete(id); selectedID = nil } onChange: { store.changed() } } else { VStack(spacing: 4) { PlanMeasurements(plan: store.plan); Text("Glisser : vue · pincer / tourner : vue · double toucher : cadrer · éditer + appui long : déplacer un élément").font(.caption2).foregroundStyle(.secondary) }.padding(10) }
        }.navigationTitle(store.selectedPlanName()).toolbar {
            ToolbarItem(placement: .topBarLeading) { Button { showLibrary = true } label: { Image(systemName: "folder") } }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu { ForEach(PlanElementKind.allCases, id: \.rawValue) { kind in Button(kind.title) { adding = kind; selectedID = nil } } } label: { Image(systemName: "plus") }.disabled(!editing)
                Menu {
                    Toggle("Numéros des murs", isOn: $overlays.wallNumbers)
                    Toggle("Longueurs", isOn: $overlays.lengths)
                    Toggle("Angles aux coins", isOn: $overlays.angles)
                    Toggle("Murs parallèles", isOn: $overlays.parallelWalls)
                } label: { Image(systemName: "square.3.layers.3d") }
                Button { show3D = true } label: { Image(systemName: "cube") }
                Button { showCaptureChoice = true } label: { Image(systemName: "viewfinder") }
            }
        }.sheet(isPresented: $showLibrary) { PlanLibraryView() }.sheet(isPresented: $show3D) { Plan3DView(plan: store.plan) }
            .confirmationDialog("Mesurer une pièce", isPresented: $showCaptureChoice, titleVisibility: .visible) {
                Button("Avec LiDAR") { confirmLidarReplacement = true }
                Button("Sans LiDAR — contact") { showContactCapture = true }
                Button("Annuler", role: .cancel) { }
            } message: { Text("Avec LiDAR, le scan remplace le plan actuel. Sans LiDAR, le relevé validé peut être enregistré dans un nouveau plan.") }
            .alert("Remplacer le plan actuel ?", isPresented: $confirmLidarReplacement) {
                Button("Continuer", role: .destructive) { store.startScan() }
                Button("Annuler", role: .cancel) { }
            } message: { Text("Le nouveau scan LiDAR remplacera le plan sélectionné. Pour conserver l’ancien, créez d’abord un nouveau plan dans le dossier.") }
            .alert("Réinitialiser les déplacements ?", isPresented: $confirmReset) {
                Button("Réinitialiser", role: .destructive) { resetMoves() }
                Button("Annuler", role: .cancel) { }
            } message: { Text("Les éléments existants retrouveront leur position au moment où vous avez activé Éditer. Les autres modifications ne seront pas annulées.") }
            .sheet(isPresented: $showContactCapture) { NavigationStack { WallSurveyStartView() } }
            .fullScreenCover(isPresented: $store.isScanning) { RoomScannerSheet() }
            .onChange(of: store.selectedPlanID) { _, _ in selectedID = nil; setEditing(false) } }
    }
}

private struct PlanMove { let id: UUID; let position: CGPoint }

private struct PlanCanvas: View {
    @Binding var elements: [PlanElement]; @Binding var selectedID: UUID?; @Binding var adding: PlanElementKind?; let viewScale: CGFloat; let viewRotation: Double; var onChange: () -> Void
    var body: some View { GeometryReader { geo in
        let metrics = PlanMetrics(elements: elements, size: geo.size)
        ZStack {
            Color(uiColor: .systemBackground).contentShape(Rectangle()).onTapGesture(coordinateSpace: .local) { point in
                guard let kind = adding else { selectedID = nil; return }
                elements.append(PlanElement(kind: kind, title: kind.title, x: metrics.worldX(point.x), z: metrics.worldZ(point.y), width: kind == .wall ? 1 : 0.8, depth: kind == .wall ? 0.10 : 0.5, rotation: 0)); adding = nil; onChange()
            }
            ZStack { if elements.isEmpty { ContentUnavailableView("Aucun plan", systemImage: "viewfinder", description: Text("Scanne une pièce ou ajoute un élément.")) }
                ForEach(elements.indices, id: \.self) { index in let value = elements[index]
                    PlanSymbol(element: value, selected: value.id == selectedID).frame(width: max(8, CGFloat(value.width) * metrics.scale), height: max(8, CGFloat(value.depth) * metrics.scale)).rotationEffect(.radians(value.rotation)).position(metrics.point(x: value.x, z: value.z)).onTapGesture { selectedID = value.id; adding = nil }.gesture(drag(for: $elements[index], metrics: metrics))
                }
            }.scaleEffect(viewScale, anchor: .center).rotationEffect(.degrees(viewRotation))
        }
    } }
    private func drag(for element: Binding<PlanElement>, metrics: PlanMetrics) -> some Gesture { DragGesture().onEnded { value in element.wrappedValue.x += Double(value.translation.width / metrics.scale); element.wrappedValue.z += Double(value.translation.height / metrics.scale); onChange() } }
}

private struct PlanSymbol: View { let element: PlanElement; let selected: Bool; var body: some View { ZStack { switch element.kind { case .wall: Rectangle().fill(.primary); case .door: Rectangle().fill(.orange).overlay(Rectangle().stroke(.primary)); case .window: Rectangle().fill(.cyan).overlay(Rectangle().stroke(.blue)); case .fixedFurniture: RoundedRectangle(cornerRadius: 4).fill(.gray); case .movableFurniture: RoundedRectangle(cornerRadius: 4).fill(.teal.opacity(0.75)) } }.overlay { if selected { RoundedRectangle(cornerRadius: 4).stroke(.yellow, lineWidth: 3) } } } }

private struct PlanViewControls: View {
    @Binding var scale: CGFloat; @Binding var rotation: Double
    var body: some View { HStack(spacing: 18) {
        Button { scale = max(0.5, scale - 0.25) } label: { Image(systemName: "minus.magnifyingglass") }
        Text("\(Int(scale * 100)) %").monospacedDigit().frame(minWidth: 48)
        Button { scale = min(3, scale + 0.25) } label: { Image(systemName: "plus.magnifyingglass") }
        Divider().frame(height: 24)
        Button { rotation -= 15 } label: { Image(systemName: "rotate.left") }
        Button { rotation += 15 } label: { Image(systemName: "rotate.right") }
        Button { scale = 1; rotation = 0 } label: { Image(systemName: "arrow.counterclockwise") }
    }.font(.headline).padding(9).frame(maxWidth: .infinity).background(.thinMaterial) }
}

private struct ElementInspector: View {
    @Binding var element: PlanElement; var editing: Bool; var onDelete: () -> Void; var onChange: () -> Void
    var body: some View { VStack(spacing: 8) { HStack { Text(element.title).font(.headline); Spacer(); Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.disabled(!editing) }; Picker("Type", selection: $element.kind) { ForEach(PlanElementKind.allCases, id: \.rawValue) { Text($0.title).tag($0) } }.pickerStyle(.menu).disabled(!editing); HStack(spacing: 14) { Measure(label: "Largeur", value: element.width); Measure(label: "Profondeur", value: element.depth); Measure(label: "Hauteur", value: element.measuredHeight) }; HStack { Button { element.rotation -= .pi / 12; onChange() } label: { Label("Tourner", systemImage: "rotate.left") }; Spacer(); Button { element.rotation += .pi / 12; onChange() } label: { Image(systemName: "rotate.right") } }.font(.footnote).disabled(!editing) }.padding().background(.thinMaterial).onChange(of: element.kind) { _, _ in onChange() } }
}

private struct Measure: View { let label: String; let value: Double; var body: some View { VStack(spacing: 2) { Text(label).font(.caption).foregroundStyle(.secondary); Text("\(value, specifier: "%.2f") m").font(.subheadline.weight(.semibold)).monospacedDigit() }.frame(maxWidth: .infinity) } }

private struct PlanMeasurements: View {
    let plan: FloorPlan
    var body: some View {
        let walls = plan.elements.filter { $0.kind == .wall }
        let total = walls.reduce(0) { $0 + $1.width }
        let area = PlanArea.area(walls: walls)
        return HStack {
            if area == nil { Text("Murs : \(total, specifier: "%.1f") m") }
            else { Text("Périmètre ≈ \(total, specifier: "%.1f") m") }
            Spacer()
            if let area { Text("Surface ≈ \(area, specifier: "%.1f") m²") }
            else { Text("Surface : contour non fermé").foregroundStyle(.secondary) }
        }.font(.footnote)
    }
}

private struct PlanLibraryView: View {
    @EnvironmentObject private var store: FloorPlanStore; @Environment(\.dismiss) private var dismiss
    @State private var newPlace = ""; @State private var newPlan = ""; @State private var creatingPlace = false; @State private var creatingPlan = false
    var body: some View { NavigationStack { List { ForEach(store.places) { place in Section(place.name) { ForEach(place.plans) { item in Button(item.name) { store.select(placeID: place.id, planID: item.id); dismiss() } }; Button("Nouveau plan") { newPlan = ""; creatingPlan = true } } } }.navigationTitle("Mes lieux").toolbar { ToolbarItem(placement: .topBarTrailing) { Button { newPlace = ""; creatingPlace = true } label: { Image(systemName: "folder.badge.plus") } } }.alert("Nouveau lieu", isPresented: $creatingPlace) { TextField("Nom", text: $newPlace); Button("Créer") { store.createPlace(named: newPlace) }; Button("Annuler", role: .cancel) {} }.alert("Nouveau plan", isPresented: $creatingPlan) { TextField("Nom", text: $newPlan); Button("Créer") { store.createPlan(named: newPlan) }; Button("Annuler", role: .cancel) {} } } }
}

private struct PlanMetrics {
    let scale: CGFloat; let minX: Double; let minZ: Double
    init(elements: [PlanElement], size: CGSize) { let xs = elements.flatMap { [$0.x - $0.width / 2, $0.x + $0.width / 2] }; let zs = elements.flatMap { [$0.z - $0.depth / 2, $0.z + $0.depth / 2] }; minX = (xs.min() ?? -1) - 0.7; minZ = (zs.min() ?? -1) - 0.7; let width = max(2, (xs.max() ?? 1) - minX + 0.7); let depth = max(2, (zs.max() ?? 1) - minZ + 0.7); scale = max(10, min(size.width / CGFloat(width), size.height / CGFloat(depth))) }
    func point(x: Double, z: Double) -> CGPoint { CGPoint(x: CGFloat(x - minX) * scale, y: CGFloat(z - minZ) * scale) }
    func worldX(_ x: CGFloat) -> Double { Double(x / scale) + minX }; func worldZ(_ z: CGFloat) -> Double { Double(z / scale) + minZ }
}
