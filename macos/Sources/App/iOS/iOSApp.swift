import SwiftUI

@main
struct Ghostty_iOSApp: App {
    @StateObject private var ghostty_app = Ghostty.App()
    
    var body: some Scene {
        WindowGroup {
            iOS_ContentView()
                .environmentObject(ghostty_app)
        }
    }
}

struct iOS_ContentView: View {
    @EnvironmentObject private var ghostty_app: Ghostty.App
    
    var body: some View {
        VStack {
            Image("AppIconImage")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 96)
            Text("Ghostty")
            Text("State: \(ghostty_app.readiness.rawValue)")
        }
        .padding()
    }
}

#Preview {
    iOS_ContentView()
}
