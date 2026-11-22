import SwiftUI

@main
struct CubeARApp: App {
    @StateObject private var floorPlan = FloorPlanStore()
    @StateObject private var surveyDrafts = WallSurveyDraftStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(floorPlan)
                .environmentObject(surveyDrafts)
        }
    }
}
