import SwiftUI
import UIKit

@main
struct Runcore: App {
    @StateObject private var store = AppStore()
    @State private var didActivateOnce = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        UITabBar.appearance().standardAppearance = appearance
        if #available(iOS 15.0, *) {
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
        .onChange(of: scenePhase) {
            guard scenePhase == .active else { return }
            if didActivateOnce {
                store.requestAnnounce(reason: "resume")
            } else {
                didActivateOnce = true
                store.requestAnnounce(reason: "startup")
            }
        }
    }
}
