import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            FloorPlanEditorView().tabItem { Label("LiDAR / Plans", systemImage: "square.3.layers.3d") }
            CameraExperimentsView().tabItem { Label("Sans LiDAR", systemImage: "camera.viewfinder") }
        }
    }
}
