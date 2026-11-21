import SwiftUI

@main
struct CubeARApp: App {
    @StateObject private var ar = ARSessionController()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(ar)
        }
    }
}
