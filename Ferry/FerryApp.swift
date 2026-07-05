import SwiftUI
import FerryCore

@main
struct FerryApp: App {
    @State private var model = ConnectionManagerModel()

    var body: some Scene {
        WindowGroup("Ferry") {
            MainWindow()
                .environment(model)
        }
        .defaultSize(width: 980, height: 620)
    }
}
