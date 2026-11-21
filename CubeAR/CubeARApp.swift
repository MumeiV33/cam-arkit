import SwiftUI

@main
struct CubeARApp: App {
    @StateObject private var floorPlan = FloorPlanStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(floorPlan)
        }
    }
}
