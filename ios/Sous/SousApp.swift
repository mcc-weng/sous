import SwiftUI

@main
struct SousApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            Group {
                if model.session == nil {
                    AuthView()
                } else {
                    CounterView()
                }
            }
            .environmentObject(model)
            .task { await model.restoreSession() }
        }
    }
}
