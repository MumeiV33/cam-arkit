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

@MainActor
final class FloorPlanStore: ObservableObject {
    @Published var plan = FloorPlan()
    @Published var isScanning = false
    @Published var message = "Scanne une pièce pour générer un premier plan."
    weak var scanner: RoomScanViewController?
    init() { load() }
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
    func addFurniture() { plan.elements.append(PlanElement(kind: .movableFurniture, title: "Meuble", x: 0, z: 0, width: 0.8, depth: 0.5, rotation: 0)); changed() }
    func changed() { plan.updatedAt = .now; save() }
    func delete(_ id: UUID) { plan.elements.removeAll { $0.id == id }; changed() }
    private func makeSurface(_ s: CapturedRoom.Surface, kind: PlanElementKind, title: String) -> PlanElement {
        let t = s.transform
        return PlanElement(kind: kind, title: title, x: Double(t.columns.3.x), z: Double(t.columns.3.z), width: max(0.08, Double(s.dimensions.x)), depth: kind == .wall ? 0.10 : max(0.10, Double(s.dimensions.z)), rotation: yaw(of: t))
    }
    private func yaw(of t: simd_float4x4) -> Double { Double(atan2(t.columns.0.z, t.columns.0.x)) }
    private var fileURL: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("floor-plan.json") }
    private func save() { do { try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true); try JSONEncoder().encode(plan).write(to: fileURL, options: .atomic) } catch { message = "Sauvegarde impossible : \(error.localizedDescription)" } }
    private func load() { guard let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(FloorPlan.self, from: data) else { return }; plan = saved; message = "Plan local restauré." }
}
