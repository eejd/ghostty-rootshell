import SwiftUI
import GhosttyKit

@main
struct MyApp: App {
    @State private var num = ghostty_hello()

    var body: some Scene {
        WindowGroup {
            Text(String(num))
              .font(.largeTitle)
        }
    }
}

struct ContentView: View {
    var body: some View {
        Text("Ghostty")
            .font(.largeTitle)
    }
}
