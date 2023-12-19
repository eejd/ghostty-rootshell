import SwiftUI

struct AboutView: View {
    /// Read the commit from the bundle.
    var build: String? { Bundle.main.infoDictionary?["CFBundleVersion"] as? String }
    var commit: String? { Bundle.main.infoDictionary?["GhosttyCommit"] as? String }
    var version: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }
    
    var body: some View {
        VStack(alignment: .center) {
            Image("AppIconImage")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 96)
            
            Text("Ghostty")
                .font(.title3)
            
            if let version = self.version {
                Text("Version: \(version)")
                    .font(.body)
            }
        }
        .frame(minWidth: 300)
        .padding()
    }
}
