import SwiftUI

struct FloorPlanEditorView: View {
    @EnvironmentObject private var store: FloorPlanStore
    @State private var selectedID: UUID?
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PlanCanvas(elements: $store.plan.elements, selectedID: $selectedID) { store.changed() }.background(Color(uiColor: .secondarySystemBackground))
                if let id = selectedID, let index = store.plan.elements.firstIndex(where: { $0.id == id }) {
                    ElementInspector(element: $store.plan.elements[index]) { store.delete(id); selectedID = nil } onChange: { store.changed() }
                } else { Text(store.message).font(.footnote).foregroundStyle(.secondary).padding(12) }
            }
            .navigationTitle("Plan de pièce")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { store.addFurniture() } label: { Label("Meuble", systemImage: "plus.rectangle.on.rectangle") } }
                ToolbarItem(placement: .topBarTrailing) { Button { store.startScan() } label: { Label("Scanner", systemImage: "viewfinder") } }
            }.fullScreenCover(isPresented: $store.isScanning) { RoomScannerSheet() }
        }
    }
}

private struct PlanCanvas: View {
    @Binding var elements: [PlanElement]; @Binding var selectedID: UUID?; var onChange: () -> Void
    var body: some View { GeometryReader { geo in
        let metrics = PlanMetrics(elements: elements, size: geo.size)
        ZStack {
            Color(uiColor: .systemBackground)
            if elements.isEmpty { ContentUnavailableView("Aucun plan", systemImage: "viewfinder", description: Text("Appuie sur Scanner et marche lentement autour de la pièce.")) }
            ForEach(elements.indices, id: \.self) { index in
                let value = elements[index]
                PlanSymbol(element: value, selected: value.id == selectedID)
                    .frame(width: max(8, CGFloat(value.width) * metrics.scale), height: max(8, CGFloat(value.depth) * metrics.scale))
                    .rotationEffect(.radians(value.rotation))
                    .position(metrics.point(x: value.x, z: value.z))
                    .onTapGesture { selectedID = value.id }
                    .gesture(drag(for: $elements[index], metrics: metrics))
            }
        }
    } }
    private func drag(for element: Binding<PlanElement>, metrics: PlanMetrics) -> some Gesture {
        DragGesture().onEnded { value in
            guard !element.wrappedValue.kind.isStructure else { return }
            element.wrappedValue.x += Double(value.translation.width / metrics.scale)
            element.wrappedValue.z += Double(value.translation.height / metrics.scale)
            onChange()
        }
    }
}

private struct PlanSymbol: View {
    let element: PlanElement; let selected: Bool
    var body: some View { ZStack { switch element.kind { case .wall: Rectangle().fill(.primary); case .door: Rectangle().fill(.orange).overlay(Rectangle().stroke(.primary)); case .window: Rectangle().fill(.cyan).overlay(Rectangle().stroke(.blue)); case .fixedFurniture: RoundedRectangle(cornerRadius: 4).fill(.gray); case .movableFurniture: RoundedRectangle(cornerRadius: 4).fill(.teal.opacity(0.75)) } }.overlay { if selected { RoundedRectangle(cornerRadius: 4).stroke(.yellow, lineWidth: 3) } } }
}

private struct ElementInspector: View {
    @Binding var element: PlanElement; var onDelete: () -> Void; var onChange: () -> Void
    var body: some View { VStack(spacing: 8) {
        HStack { Text(element.title).font(.headline); Spacer(); if !element.kind.isStructure { Picker("Type", selection: $element.kind) { Text("Mobile").tag(PlanElementKind.movableFurniture); Text("Fixe").tag(PlanElementKind.fixedFurniture) }.pickerStyle(.segmented).frame(maxWidth: 180) } }
        if !element.kind.isStructure { HStack { Button { element.rotation -= .pi / 12; onChange() } label: { Image(systemName: "rotate.left") }; Spacer(); Button(role: .destructive, action: onDelete) { Label("Supprimer", systemImage: "trash") }; Spacer(); Button { element.rotation += .pi / 12; onChange() } label: { Image(systemName: "rotate.right") } } }
    }.padding().background(.thinMaterial).onChange(of: element.kind) { _, _ in onChange() } }
}

private struct PlanMetrics {
    let scale: CGFloat; let minX: Double; let minZ: Double
    init(elements: [PlanElement], size: CGSize) {
        let xs = elements.flatMap { [$0.x - $0.width / 2, $0.x + $0.width / 2] }; let zs = elements.flatMap { [$0.z - $0.depth / 2, $0.z + $0.depth / 2] }
        minX = (xs.min() ?? -1) - 0.7; minZ = (zs.min() ?? -1) - 0.7
        let width = max(2, (xs.max() ?? 1) - minX + 0.7); let depth = max(2, (zs.max() ?? 1) - minZ + 0.7)
        scale = max(10, min(size.width / CGFloat(width), size.height / CGFloat(depth)))
    }
    func point(x: Double, z: Double) -> CGPoint { CGPoint(x: CGFloat(x - minX) * scale, y: CGFloat(z - minZ) * scale) }
}
