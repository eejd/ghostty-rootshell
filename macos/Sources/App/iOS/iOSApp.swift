import SwiftUI

@main
struct Ghostty_iOSApp: App {
    var body: some Scene {
        WindowGroup {
            iOS_ContentView()
        }
    }
}

struct iOS_ContentView: View {
    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Hello, world!")
        }
        .padding()
    }
}

#Preview {
    iOS_ContentView()
}
