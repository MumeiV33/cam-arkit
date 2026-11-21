import Foundation
import RoomPlan
import simd

enum PlanElementKind: String, Codable, CaseIterable {
    case wall, door, window, fixedFurniture, movableFurniture
    var title: String { switch self { case .wall: "Mur"; case .door: "Porte"; case .window: "Fenêtre"; case .fixedFurniture: "Mobilier fixe"; case .movableFurniture: "Mobilier mobile" } }
    var isStructure: Bool { self == .wall || self == .door || self == .window }
}

struct PlanElement: Identifiable, Codable, Equatable {
    var id = UUID(); var kind: PlanElementKind; var title: String
    var x: Double; var z: Double; var width: Double; var depth: Double; var rotation: Double
}

struct FloorPlan: Codable { var elements: [PlanElement] = []; var updatedAt = Date() }
struct SavedPlan: Identifiable, Codable { var id = UUID(); var name: String; var plan = FloorPlan() }
struct Place: Identifiable, Codable { var id = UUID(); var name: String; var plans: [SavedPlan] }
struct PlanLibrary: Codable { var places: [Place] }

@MainActor
final class FloorPlanStore: ObservableObject {
    @Published var plan = FloorPlan()
    @Published var places: [Place] = []
    @Published var selectedPlaceID: UUID?
    @Published var selectedPlanID: UUID?
    @Published var isScanning = false
    @Published var message = "Scanne une pièce pour générer un premier plan."
    weak var scanner: RoomScanViewController?
    init() { load(); ensureSelection() }
    var isSupported: Bool { RoomCaptureSession.isSupported }
    func startScan() { guard isSupported else { message = "Cet appareil n’a pas de capteur LiDAR compatible avec RoomPlan."; return }; isScanning = true }
    func stopScan() { scanner?.stopCapture() }
    func replace(with room: CapturedRoom) {
        var values = room.walls.map { makeSurface($0, kind: .wall, title: "Mur") }
        values += room.doors.map { makeSurface($0, kind: .door, title: "Porte") }
        values += room.windows.map { makeSurface($0, kind: .window, title: "Fenêtre") }
        values += room.objects.map { object in
            let t = object.transform
            return PlanElement(kind: .movableFurniture, title: String(describing: object.category).capitalized, x: Double(t.columns.3.x), z: Double(t.columns.3.z), width: max(0.20, Double(object.dimensions.x)), depth: max(0.20, Double(object.dimensions.z)), rotation: yaw(of: t))
        }
        plan = FloorPlan(elements: values, updatedAt: .now); save()
        message = "Plan créé : \(room.walls.count) murs, \(room.doors.count) portes et \(room.windows.count) fenêtres."
        isScanning = false
    }
    func createPlace(named name: String) {
        let first = SavedPlan(name: "Plan 1")
        let place = Place(name: name.isEmpty ? "Nouveau lieu" : name, plans: [first])
        places.append(place); selectedPlaceID = place.id; selectedPlanID = first.id; plan = first.plan; save()
    }
    func createPlan(named name: String) {
        guard let placeIndex = places.firstIndex(where: { $0.id == selectedPlaceID }) else { return }
        let item = SavedPlan(name: name.isEmpty ? "Nouveau plan" : name)
        places[placeIndex].plans.append(item); selectedPlanID = item.id; plan = item.plan; save()
    }
    func select(placeID: UUID, planID: UUID) {
        persistCurrentPlan()
        selectedPlaceID = placeID; selectedPlanID = planID
        plan = places.first(where: { $0.id == placeID })?.plans.first(where: { $0.id == planID })?.plan ?? FloorPlan()
    }
    func selectedPlanName() -> String { places.first(where: { $0.id == selectedPlaceID })?.plans.first(where: { $0.id == selectedPlanID })?.name ?? "Plan" }
    func addFurniture() { plan.elements.append(PlanElement(kind: .movableFurniture, title: "Meuble", x: 0, z: 0, width: 0.8, depth: 0.5, rotation: 0)); changed() }
    func changed() { plan.updatedAt = .now; save() }
    func delete(_ id: UUID) { plan.elements.removeAll { $0.id == id }; changed() }
    private func makeSurface(_ s: CapturedRoom.Surface, kind: PlanElementKind, title: String) -> PlanElement {
        let t = s.transform
        return PlanElement(kind: kind, title: title, x: Double(t.columns.3.x), z: Double(t.columns.3.z), width: max(0.08, Double(s.dimensions.x)), depth: kind == .wall ? 0.10 : max(0.10, Double(s.dimensions.z)), rotation: yaw(of: t))
    }
    private func yaw(of t: simd_float4x4) -> Double { Double(atan2(t.columns.0.z, t.columns.0.x)) }
    private var fileURL: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("places.json") }
    private func persistCurrentPlan() {
        guard let placeIndex = places.firstIndex(where: { $0.id == selectedPlaceID }), let planIndex = places[placeIndex].plans.firstIndex(where: { $0.id == selectedPlanID }) else { return }
        places[placeIndex].plans[planIndex].plan = plan
    }
    private func save() { persistCurrentPlan(); do { try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true); try JSONEncoder().encode(PlanLibrary(places: places)).write(to: fileURL, options: .atomic) } catch { message = "Sauvegarde impossible : \(error.localizedDescription)" } }
    private func load() { guard let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(PlanLibrary.self, from: data) else { return }; places = saved.places; message = "Bibliothèque locale restaurée." }
    private func ensureSelection() { if places.isEmpty { createPlace(named: "Mes lieux") } else if let place = places.first, let first = place.plans.first { selectedPlaceID = place.id; selectedPlanID = first.id; plan = first.plan } }
}
