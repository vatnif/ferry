import SwiftUI
import FerryCore

@main
struct FerryApp: App {
    var body: some Scene {
        WindowGroup("Ferry") {
            PlaceholderView()
        }
        .defaultSize(width: 560, height: 380)
    }
}

/// M1 scaffold window. Replaced by the connection manager + dual-pane
/// browser (docs/DESIGN.md) starting in M4.
struct PlaceholderView: View {
    private var distribution: String {
        #if APPSTORE
        return "App Store build"
        #else
        return "Direct build"
        #endif
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Ferry")
                .font(.system(size: 28, weight: .bold))
            Text("Milestone 1 scaffold — the real UI ships from M4 per docs/DESIGN.md")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("v\(FerryVersion.current) · \(distribution)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    PlaceholderView()
}
