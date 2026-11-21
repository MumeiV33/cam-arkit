import Foundation
import Combine

@MainActor
final class ARSessionController: ObservableObject {
    weak var controller: ARViewController?
    @Published var hasSelection = false
    @Published var status = "Cherchez une surface plane, puis touchez-la"

    func rotateSelected(by radians: Float) { controller?.rotateSelected(by: radians) }
    func deleteSelected() { controller?.deleteSelected() }
    func save() { controller?.saveWorld() }
    func load() { controller?.loadWorld() }
}
