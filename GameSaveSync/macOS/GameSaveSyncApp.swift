import SwiftUI

@main
struct GameSaveSyncApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .frame(minWidth: 620, minHeight: 460)
        }
        .defaultSize(width: 760, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
