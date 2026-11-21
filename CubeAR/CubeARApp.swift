import SwiftUI

@main
struct CubeARApp: App {
    @StateObject private var ar = ARSessionController()
    @StateObject private var floorPlan = FloorPlanStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ar)
                .environmentObject(floorPlan)
        }
    }
}
