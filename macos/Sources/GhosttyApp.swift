import SwiftUI
import GhosttyKit

@main
struct GhosttyApp: App {
    init() {
        assert(ghostty_init() == GHOSTTY_SUCCESS, "ghostty failed to initialize");
    }
    
    var body: some Scene {
        WindowGroup {
            Text("Hello!").font(.largeTitle)
        }
    }
}
