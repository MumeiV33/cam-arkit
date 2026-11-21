import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var ar: ARSessionController

    var body: some View {
        ZStack {
            ARViewContainer().ignoresSafeArea()

            VStack(spacing: 12) {
                Text(ar.status)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.black.opacity(0.58), in: Capsule())

                Spacer()

                if ar.hasSelection {
                    HStack(spacing: 14) {
                        Button { ar.rotateSelected(by: -.pi / 12) } label: { Image(systemName: "rotate.left") }
                        Button { ar.deleteSelected() } label: { Image(systemName: "trash") }
                            .tint(.red)
                        Button { ar.rotateSelected(by: .pi / 12) } label: { Image(systemName: "rotate.right") }
                    }
                    .buttonStyle(ARControlButtonStyle())
                }

                HStack(spacing: 14) {
                    Button { ar.save() } label: { Label("Sauvegarder", systemImage: "square.and.arrow.down") }
                    Button { ar.load() } label: { Label("Restaurer", systemImage: "arrow.counterclockwise") }
                }
                .buttonStyle(ARControlButtonStyle())
            }
            .padding(.top, 60).padding(.bottom, 34)
        }
    }
}

private struct ARControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(minWidth: 46, minHeight: 46)
            .padding(.horizontal, 10)
            .background(.black.opacity(configuration.isPressed ? 0.8 : 0.62), in: Capsule())
    }
}

struct ARViewContainer: UIViewControllerRepresentable {
    @EnvironmentObject private var ar: ARSessionController

    func makeUIViewController(context: Context) -> ARViewController {
        let controller = ARViewController()
        ar.controller = controller
        controller.sessionModel = ar
        return controller
    }

    func updateUIViewController(_ uiViewController: ARViewController, context: Context) {}
}
