import SwiftUI

@main
struct Ghostty: App {
  var body: some Scene {
    WindowGroup {
      ContentView()
    }
  }
}

struct ContentView: View {
  @StateObject var viewModel: ViewModel  = ViewModel()

  var body: some View {
    TextField("", text: $viewModel.inputText)
      .padding()
  }
}

public class ViewModel: ObservableObject {
  @Published var inputText: String = ""
}
