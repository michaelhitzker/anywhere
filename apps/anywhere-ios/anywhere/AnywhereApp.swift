import SwiftUI

@main
struct AnywhereApp: App {
    @State private var store = PhoneCompanionStore()

    var body: some Scene {
        WindowGroup {
            PhoneRootView(store: store)
                .preferredColorScheme(.dark)
        }
    }
}
