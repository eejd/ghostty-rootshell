import SwiftUI
import GhosttyKit

@main
struct GhosttyApp: App {
    @State private var num = ghostty_hello()
    
    var body: some Scene {
        WindowGroup {
            Text(String(num)).font(.largeTitle)
        }
    }
}
