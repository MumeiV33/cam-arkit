import ARKit
import SceneKit

final class ARViewController: UIViewController, ARSCNViewDelegate, ARSessionDelegate {
    private let sceneView = ARSCNView(frame: .zero)
    private var cubeAnchors: [UUID: CubeAnchor] = [:]
    private var cubeNodes: [UUID: SCNNode] = [:]
    private var selectedID: UUID?

    // The SwiftUI bridge sets this after construction; this reference drives UI state.
    weak var sessionModel: ARSessionController?

    override func viewDidLoad() {
        super.viewDidLoad()
        sceneView.frame = view.bounds
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.delegate = self
        sceneView.session.delegate = self
        sceneView.automaticallyUpdatesLighting = true
        sceneView.debugOptions = [.showFeaturePoints]
        view.addSubview(sceneView)
        sceneView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        runSession()
    }

    private func runSession(initialWorldMap: ARWorldMap? = nil) {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.environmentTexturing = .automatic
        configuration.initialWorldMap = initialWorldMap
        sceneView.session.run(configuration, options: initialWorldMap == nil ? [] : [.resetTracking, .removeExistingAnchors])
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: sceneView)
        if let hit = sceneView.hitTest(point, options: nil).first,
           let id = cubeID(containing: hit.node) {
            select(id)
            return
        }
        let query = sceneView.raycastQuery(from: point, allowing: .estimatedPlane, alignment: .any)
        guard let query, let result = sceneView.session.raycast(query).first else {
            setStatus("Aucune surface détectée : bougez lentement l’iPhone.")
            return
        }
        let anchor = CubeAnchor(transform: result.worldTransform)
        cubeAnchors[anchor.identifier] = anchor
        sceneView.session.add(anchor: anchor)
        setStatus("Cube ajouté. Touchez-le pour le sélectionner.")
    }

    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        guard let anchor = anchor as? CubeAnchor else { return }
        let cube = makeCube()
        cube.name = CubeAnchor.typeName
        node.addChildNode(cube)
        DispatchQueue.main.async {
            self.cubeAnchors[anchor.identifier] = anchor
            self.cubeNodes[anchor.identifier] = cube
        }
    }

    private func makeCube() -> SCNNode {
        let geometry = SCNBox(width: 0.10, height: 0.10, length: 0.10, chamferRadius: 0.008)
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemBlue.withAlphaComponent(0.88)
        material.metalness.contents = 0.15
        material.roughness.contents = 0.35
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }

    private func cubeID(containing node: SCNNode) -> UUID? {
        guard node.name == CubeAnchor.typeName else { return nil }
        return cubeNodes.first(where: { $0.value === node })?.key
    }

    private func select(_ id: UUID?) {
        selectedID = id
        cubeNodes.forEach { key, node in
            node.geometry?.firstMaterial?.emission.contents = key == id ? UIColor.systemYellow : UIColor.black
        }
        sessionModel?.hasSelection = id != nil
        if id != nil { setStatus("Cube sélectionné : orientez-le ou supprimez-le.") }
    }

    func rotateSelected(by radians: Float) {
        guard let id = selectedID, let oldAnchor = cubeAnchors[id] else { return }
        var rotation = matrix_identity_float4x4
        rotation.columns.0.x = cos(radians); rotation.columns.0.z = -sin(radians)
        rotation.columns.2.x = sin(radians); rotation.columns.2.z = cos(radians)
        let replacement = CubeAnchor(transform: simd_mul(oldAnchor.transform, rotation))
        sceneView.session.remove(anchor: oldAnchor)
        cubeAnchors.removeValue(forKey: id); cubeNodes.removeValue(forKey: id)
        selectedID = replacement.identifier
        cubeAnchors[replacement.identifier] = replacement
        sceneView.session.add(anchor: replacement)
        DispatchQueue.main.async { self.select(replacement.identifier) }
    }

    func deleteSelected() {
        guard let id = selectedID, let anchor = cubeAnchors[id] else { return }
        sceneView.session.remove(anchor: anchor)
        cubeAnchors.removeValue(forKey: id); cubeNodes.removeValue(forKey: id)
        select(nil)
        setStatus("Cube supprimé.")
    }

    func saveWorld() {
        sceneView.session.getCurrentWorldMap { [weak self] map, error in
            DispatchQueue.main.async {
                guard let self, let map else { self?.setStatus("Sauvegarde impossible : \(error?.localizedDescription ?? "cartographie indisponible")"); return }
                do {
                    try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true).write(to: self.mapURL, options: .atomic)
                    self.setStatus("Positions et carte AR sauvegardées.")
                } catch { self.setStatus("Erreur de sauvegarde : \(error.localizedDescription)") }
            }
        }
    }

    func loadWorld() {
        do {
            let data = try Data(contentsOf: mapURL)
            guard let map = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else { throw CocoaError(.fileReadCorruptFile) }
            cubeAnchors.removeAll(); cubeNodes.removeAll(); select(nil)
            runSession(initialWorldMap: map)
            setStatus("Carte restaurée. Visez le même lieu pour la relocalisation.")
        } catch { setStatus("Aucune sauvegarde lisible : \(error.localizedDescription)") }
    }

    private var mapURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("cube-worldmap.arexperience")
    }

    private func setStatus(_ text: String) { sessionModel?.status = text }
}
