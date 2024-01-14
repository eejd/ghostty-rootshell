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
            Image("AppIconImage")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 96)
            Text("Ghostty")
        }
        .padding()
    }
}

#Preview {
    iOS_ContentView()
}
