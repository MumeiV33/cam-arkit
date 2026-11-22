import SwiftUI
import UIKit

struct PlanOverlayOptions {
    var wallNumbers = true
    var lengths = true
    var angles = false
    var parallelWalls = false
}

struct InteractivePlanView: UIViewRepresentable {
    @Binding var elements: [PlanElement]
    @Binding var selectedID: UUID?
    @Binding var adding: PlanElementKind?
    var overlays: PlanOverlayOptions
    var planID: UUID?
    var onChange: () -> Void

    func makeUIView(context: Context) -> InteractivePlanCanvas {
        let view = InteractivePlanCanvas()
        view.onSelect = { selectedID = $0 }
        view.onAdd = { point in
            guard let kind = adding else { selectedID = nil; return }
            elements.append(PlanElement(kind: kind, title: kind.title, x: Double(point.x), z: Double(point.y), width: kind == .wall ? 1 : 0.8, depth: kind == .wall ? 0.10 : 0.5, rotation: 0))
            adding = nil; onChange()
        }
        view.onMove = { id, delta in
            guard let index = elements.firstIndex(where: { $0.id == id }) else { return }
            elements[index].x += Double(delta.x); elements[index].z += Double(delta.y); onChange()
        }
        return view
    }
    func updateUIView(_ view: InteractivePlanCanvas, context: Context) {
        let wasEmpty = view.elements.isEmpty
        view.elements = elements; view.selectedID = selectedID; view.adding = adding != nil
        view.overlays = overlays; view.setPlanID(planID)
        if wasEmpty && !elements.isEmpty { view.requestFit() }
        view.setNeedsDisplay()
    }
}

final class InteractivePlanCanvas: UIView, UIGestureRecognizerDelegate {
    var elements: [PlanElement] = []
    var selectedID: UUID?
    var adding = false
    var overlays = PlanOverlayOptions()
    var onSelect: ((UUID?) -> Void)?
    var onAdd: ((CGPoint) -> Void)?
    var onMove: ((UUID, CGPoint) -> Void)?
    private var planID: UUID?
    private var initialized = false
    private var pointsPerMetre: CGFloat = 80
    private var translation = CGPoint.zero
    private var rotation: CGFloat = 0
    private var moveID: UUID?
    private var moveStart = CGPoint.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground; isMultipleTouchEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(resetView(_:)))
        doubleTap.numberOfTapsRequired = 2; tap.require(toFail: doubleTap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(rotated(_:)))
        let move = UILongPressGestureRecognizer(target: self, action: #selector(moved(_:)))
        move.minimumPressDuration = 0.45; move.allowableMovement = 12
        pan.require(toFail: move)
        for gesture in [tap, doubleTap, pan, pinch, rotate, move] { gesture.delegate = self; addGestureRecognizer(gesture) }
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    func setPlanID(_ id: UUID?) { if id != planID { planID = id; initialized = false; setNeedsLayout() } }
    func requestFit() { initialized = false; setNeedsLayout() }
    override func layoutSubviews() { super.layoutSubviews(); if !initialized && bounds.width > 0 && bounds.height > 0 { fitPlan(); initialized = true } }
    private func fitPlan() {
        let corners = elements.flatMap { elementCorners($0) }
        guard let minX = corners.map(\.x).min(), let maxX = corners.map(\.x).max(), let minY = corners.map(\.y).min(), let maxY = corners.map(\.y).max() else {
            pointsPerMetre = 80; translation = CGPoint(x: bounds.midX, y: bounds.midY); rotation = 0; return
        }
        let width = max(1, maxX-minX), height = max(1, maxY-minY)
        pointsPerMetre = max(10, min((bounds.width-80)/width, (bounds.height-80)/height))
        rotation = 0
        translation = CGPoint(x: bounds.midX - (minX+maxX)/2 * pointsPerMetre, y: bounds.midY - (minY+maxY)/2 * pointsPerMetre)
    }
    private func toScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: translation.x + pointsPerMetre * (cos(rotation)*p.x - sin(rotation)*p.y), y: translation.y + pointsPerMetre * (sin(rotation)*p.x + cos(rotation)*p.y))
    }
    private func toWorld(_ p: CGPoint) -> CGPoint {
        let x = (p.x-translation.x)/pointsPerMetre, y = (p.y-translation.y)/pointsPerMetre
        return CGPoint(x: cos(rotation)*x + sin(rotation)*y, y: -sin(rotation)*x + cos(rotation)*y)
    }
    private func elementCorners(_ element: PlanElement) -> [CGPoint] {
        let angle = CGFloat(element.rotation), c = cos(angle), s = sin(angle)
        return [(-1.0,-1.0),(1.0,-1.0),(1.0,1.0),(-1.0,1.0)].map { x, y in
            let dx = CGFloat(x * element.width / 2), dy = CGFloat(y * element.depth / 2)
            return CGPoint(x: CGFloat(element.x)+c*dx-s*dy, y: CGFloat(element.z)+s*dx+c*dy)
        }
    }
    private func wallEndpoints(_ wall: PlanElement) -> (CGPoint, CGPoint) {
        let d = CGPoint(x: CGFloat(cos(wall.rotation)*wall.width/2), y: CGFloat(sin(wall.rotation)*wall.width/2))
        return (CGPoint(x: CGFloat(wall.x)-d.x, y: CGFloat(wall.z)-d.y), CGPoint(x: CGFloat(wall.x)+d.x, y: CGFloat(wall.z)+d.y))
    }
    private func hit(_ point: CGPoint) -> UUID? {
        let world = toWorld(point)
        return elements.reversed().first { element in
            let dx = world.x-CGFloat(element.x), dy = world.y-CGFloat(element.z), angle = CGFloat(element.rotation)
            let x = cos(angle)*dx+sin(angle)*dy, y = -sin(angle)*dx+cos(angle)*dy
            return abs(x) <= CGFloat(element.width/2)+12/pointsPerMetre && abs(y) <= CGFloat(element.depth/2)+12/pointsPerMetre
        }?.id
    }
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        if adding { onAdd?(toWorld(point)) } else { onSelect?(hit(point)) }
    }
    @objc private func resetView(_ gesture: UITapGestureRecognizer) { fitPlan(); setNeedsDisplay() }
    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        let delta = gesture.translation(in: self); translation.x += delta.x; translation.y += delta.y
        gesture.setTranslation(.zero, in: self); setNeedsDisplay()
    }
    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        let center = gesture.location(in: self), world = toWorld(center)
        pointsPerMetre = max(15, min(800, pointsPerMetre * gesture.scale)); gesture.scale = 1
        let projected = toScreen(world); translation.x += center.x-projected.x; translation.y += center.y-projected.y; setNeedsDisplay()
    }
    @objc private func rotated(_ gesture: UIRotationGestureRecognizer) {
        let center = gesture.location(in: self), world = toWorld(center)
        rotation += gesture.rotation; gesture.rotation = 0
        let projected = toScreen(world); translation.x += center.x-projected.x; translation.y += center.y-projected.y; setNeedsDisplay()
    }
    @objc private func moved(_ gesture: UILongPressGestureRecognizer) {
        let location = gesture.location(in: self)
        if gesture.state == .began { moveID = hit(location); moveStart = toWorld(location); if let moveID { onSelect?(moveID) } }
        if gesture.state == .ended, let id = moveID {
            let end = toWorld(location); onMove?(id, CGPoint(x: end.x-moveStart.x, y: end.y-moveStart.y)); moveID = nil
        }
        if gesture.state == .cancelled || gesture.state == .failed { moveID = nil }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        (gestureRecognizer is UIPinchGestureRecognizer || gestureRecognizer is UIRotationGestureRecognizer) && (otherGestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIRotationGestureRecognizer)
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UILongPressGestureRecognizer { return !adding && hit(gestureRecognizer.location(in: self)) != nil }
        return true
    }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let walls = elements.filter { $0.kind == .wall }
        for element in elements {
            let points = elementCorners(element).map(toScreen)
            guard let first = points.first else { continue }
            let path = UIBezierPath(); path.move(to: first); points.dropFirst().forEach { path.addLine(to: $0) }; path.close()
            color(element.kind).setFill(); path.fill()
            if selectedID == element.id { UIColor.systemYellow.setStroke(); path.lineWidth = 3; path.stroke() }
        }
        for (index, wall) in walls.enumerated() {
            let midpoint = toScreen(CGPoint(x: CGFloat(wall.x), y: CGFloat(wall.z)))
            let parallel = walls.enumerated().contains { otherIndex, other in
                guard index != otherIndex else { return false }
                return abs(sin(wall.rotation-other.rotation)) < sin(5 * .pi / 180)
            }
            var parts: [String] = []
            if overlays.wallNumbers { parts.append("M\(index+1)") }
            if overlays.lengths { parts.append(String(format: "%.2f m", wall.width)) }
            if overlays.parallelWalls && parallel { parts.append("∥") }
            if !parts.isEmpty { drawLabel(parts.joined(separator: " · "), at: CGPoint(x: midpoint.x, y: midpoint.y-15), color: parallel && overlays.parallelWalls ? .systemPurple : .label) }
        }
        if overlays.angles { drawAngles(walls, context: context) }
    }
    private func drawAngles(_ walls: [PlanElement], context: CGContext) {
        guard walls.count > 1 else { return }
        for i in 0..<(walls.count-1) { for j in (i+1)..<walls.count {
            let a = wallEndpoints(walls[i]), b = wallEndpoints(walls[j])
            let pairs = [(a.0,a.1,b.0,b.1),(a.0,a.1,b.1,b.0),(a.1,a.0,b.0,b.1),(a.1,a.0,b.1,b.0)]
            guard let nearest = pairs.min(by: { hypot($0.0.x-$0.2.x,$0.0.y-$0.2.y) < hypot($1.0.x-$1.2.x,$1.0.y-$1.2.y) }), hypot(nearest.0.x-nearest.2.x,nearest.0.y-nearest.2.y) <= 0.15 else { continue }
            let v1 = CGPoint(x: nearest.1.x-nearest.0.x, y: nearest.1.y-nearest.0.y), v2 = CGPoint(x: nearest.3.x-nearest.2.x, y: nearest.3.y-nearest.2.y)
            let denominator = hypot(v1.x,v1.y)*hypot(v2.x,v2.y)
            guard denominator > 0.001 else { continue }
            let degrees = acos(max(-1, min(1, (v1.x*v2.x+v1.y*v2.y)/denominator)))*180 / .pi
            let point = toScreen(CGPoint(x: (nearest.0.x+nearest.2.x)/2, y: (nearest.0.y+nearest.2.y)/2))
            drawLabel(String(format: "%.0f°", Double(degrees)), at: CGPoint(x: point.x+15, y: point.y+16), color: abs(degrees-90) > 3 ? .systemOrange : .secondaryLabel)
        } }
    }
    private func drawLabel(_ text: String, at point: CGPoint, color: UIColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: color, .backgroundColor: UIColor.systemBackground.withAlphaComponent(0.85)]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: CGPoint(x: point.x-size.width/2, y: point.y-size.height/2), withAttributes: attrs)
    }
    private func color(_ kind: PlanElementKind) -> UIColor { switch kind { case .wall: .label; case .door: .systemOrange; case .window: .systemCyan; case .fixedFurniture: .systemGray; case .movableFurniture: .systemTeal } }
}
