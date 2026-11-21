import SwiftUI

struct FloorPlanEditorView: View {
    @EnvironmentObject private var store: FloorPlanStore
    @State private var selectedID: UUID?
    @State private var adding: PlanElementKind?
    @State private var showLibrary = false
    @State private var show3D = false
    var body: some View {
        NavigationStack { VStack(spacing: 0) {
            if let adding { Text("Touchez le plan pour ajouter : \(adding.title)").font(.footnote.weight(.semibold)).padding(8).frame(maxWidth: .infinity).background(.orange.opacity(0.25)) }
            PlanCanvas(elements: $store.plan.elements, selectedID: $selectedID, adding: $adding) { store.changed() }.clipped().background(Color(uiColor: .secondarySystemBackground))
            if let id = selectedID, let index = store.plan.elements.firstIndex(where: { $0.id == id }) { ElementInspector(element: $store.plan.elements[index]) { store.delete(id); selectedID = nil } onChange: { store.changed() } } else { PlanMeasurements(plan: store.plan).padding(10) }
        }.navigationTitle(store.selectedPlanName()).toolbar {
            ToolbarItem(placement: .topBarLeading) { Button { showLibrary = true } label: { Image(systemName: "folder") } }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu { ForEach(PlanElementKind.allCases, id: \.rawValue) { kind in Button(kind.title) { adding = kind; selectedID = nil } } } label: { Image(systemName: "plus") }
                Button { show3D = true } label: { Image(systemName: "cube") }
                Button { store.startScan() } label: { Image(systemName: "viewfinder") }
            }
        }.sheet(isPresented: $showLibrary) { PlanLibraryView() }.sheet(isPresented: $show3D) { Plan3DView(plan: store.plan) }.fullScreenCover(isPresented: $store.isScanning) { RoomScannerSheet() } }
    }
}

private struct PlanCanvas: View {
    @Binding var elements: [PlanElement]; @Binding var selectedID: UUID?; @Binding var adding: PlanElementKind?; var onChange: () -> Void
    var body: some View { GeometryReader { geo in
        let metrics = PlanMetrics(elements: elements, size: geo.size)
        ZStack {
            Color(uiColor: .systemBackground).contentShape(Rectangle()).onTapGesture(coordinateSpace: .local) { point in
                guard let kind = adding else { selectedID = nil; return }
                elements.append(PlanElement(kind: kind, title: kind.title, x: metrics.worldX(point.x), z: metrics.worldZ(point.y), width: kind == .wall ? 1 : 0.8, depth: kind == .wall ? 0.10 : 0.5, rotation: 0)); adding = nil; onChange()
            }
            if elements.isEmpty { ContentUnavailableView("Aucun plan", systemImage: "viewfinder", description: Text("Scanne une pièce ou ajoute un élément.")) }
            ForEach(elements.indices, id: \.self) { index in let value = elements[index]
                PlanSymbol(element: value, selected: value.id == selectedID).frame(width: max(8, CGFloat(value.width) * metrics.scale), height: max(8, CGFloat(value.depth) * metrics.scale)).rotationEffect(.radians(value.rotation)).position(metrics.point(x: value.x, z: value.z)).onTapGesture { selectedID = value.id; adding = nil }.gesture(drag(for: $elements[index], metrics: metrics))
            }
        }
    } }
    private func drag(for element: Binding<PlanElement>, metrics: PlanMetrics) -> some Gesture { DragGesture().onEnded { value in element.wrappedValue.x += Double(value.translation.width / metrics.scale); element.wrappedValue.z += Double(value.translation.height / metrics.scale); onChange() } }
}

private struct PlanSymbol: View { let element: PlanElement; let selected: Bool; var body: some View { ZStack { switch element.kind { case .wall: Rectangle().fill(.primary); case .door: Rectangle().fill(.orange).overlay(Rectangle().stroke(.primary)); case .window: Rectangle().fill(.cyan).overlay(Rectangle().stroke(.blue)); case .fixedFurniture: RoundedRectangle(cornerRadius: 4).fill(.gray); case .movableFurniture: RoundedRectangle(cornerRadius: 4).fill(.teal.opacity(0.75)) } }.overlay { if selected { RoundedRectangle(cornerRadius: 4).stroke(.yellow, lineWidth: 3) } } } }

private struct ElementInspector: View {
    @Binding var element: PlanElement; var onDelete: () -> Void; var onChange: () -> Void
    var body: some View { VStack(spacing: 8) { HStack { Text(element.title).font(.headline); Spacer(); Button(role: .destructive, action: onDelete) { Image(systemName: "trash") } }; Picker("Type", selection: $element.kind) { ForEach(PlanElementKind.allCases, id: \.rawValue) { Text($0.title).tag($0) } }.pickerStyle(.menu); HStack { Text("L × P : \(element.width, specifier: "%.2f") m × \(element.depth, specifier: "%.2f") m"); Spacer(); Button { element.rotation -= .pi / 12; onChange() } label: { Image(systemName: "rotate.left") }; Button { element.rotation += .pi / 12; onChange() } label: { Image(systemName: "rotate.right") } }.font(.footnote) }.padding().background(.thinMaterial).onChange(of: element.kind) { _, _ in onChange() } }
}

private struct PlanMeasurements: View { let plan: FloorPlan; var body: some View { let walls = plan.elements.filter { $0.kind == .wall }.reduce(0) { $0 + $1.width }; let doors = plan.elements.filter { $0.kind == .door }.count; let windows = plan.elements.filter { $0.kind == .window }.count; return HStack { Label("Murs : \(walls, specifier: "%.1f") m", systemImage: "ruler"); Spacer(); Text("\(doors) portes · \(windows) fenêtres").foregroundStyle(.secondary) }.font(.footnote) } }

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
