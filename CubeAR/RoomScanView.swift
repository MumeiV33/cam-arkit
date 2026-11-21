import SwiftUI
import RoomPlan

struct RoomScannerSheet: View {
    @EnvironmentObject private var store: FloorPlanStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ZStack(alignment: .bottom) {
            RoomScanContainer().ignoresSafeArea()
            HStack { Button("Annuler") { store.isScanning = false; dismiss() }; Spacer(); Button("Terminer") { store.stopScan() }.fontWeight(.bold) }
                .foregroundStyle(.white).padding().background(.black.opacity(0.65), in: Capsule()).padding(.bottom, 36)
        }.onChange(of: store.isScanning) { _, scanning in if !scanning { dismiss() } }
    }
}

struct RoomScanContainer: UIViewControllerRepresentable {
    @EnvironmentObject private var store: FloorPlanStore
    func makeUIViewController(context: Context) -> RoomScanViewController {
        let controller = RoomScanViewController()
        controller.onFinished = { room in Task { @MainActor in store.replace(with: room) } }
        controller.onFailure = { text in Task { @MainActor in store.message = text; store.isScanning = false } }
        store.scanner = controller
        return controller
    }
    func updateUIViewController(_ uiViewController: RoomScanViewController, context: Context) {}
}

final class RoomScanViewController: UIViewController, RoomCaptureViewDelegate {
    private var captureView: RoomCaptureView!
    var onFinished: ((CapturedRoom) -> Void)?; var onFailure: ((String) -> Void)?
    override func viewDidLoad() {
        super.viewDidLoad(); captureView = RoomCaptureView(frame: view.bounds)
        captureView.autoresizingMask = [.flexibleWidth, .flexibleHeight]; captureView.delegate = self; view.addSubview(captureView)
        captureView.captureSession.run(configuration: .init())
    }
    func stopCapture() { captureView.captureSession.stop() }
    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool { true }
    func captureView(didPresent processedResult: CapturedRoom, error: Error?) { if let error { onFailure?("Scan impossible : \(error.localizedDescription)") } else { onFinished?(processedResult) } }
}
