import SwiftUI

@main
struct CanliCeviriApp: App {
    @StateObject private var engine = Engine.shared
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .environmentObject(settings)
        }
    }
}
