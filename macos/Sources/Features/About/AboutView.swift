import SwiftUI

struct AboutView: View {
    /// Read the commit from the bundle.
    var commit: String {
        guard let valueAny = Bundle.main.infoDictionary?["CFBundleVersion"],
              let version = valueAny as? String else {
            return "unknown"
        }
        
        return version
    }
    
    var body: some View {
        VStack(alignment: .center) {
            Image("AppIconImage")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 96)
            
            Text("Ghostty")
                .font(.title3)
            
            Text("Commit: \(commit)")
                .font(.body)
        }
        .frame(minWidth: 300)
        .padding()
    }
}
