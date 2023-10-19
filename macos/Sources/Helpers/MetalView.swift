import SwiftUI
import MetalKit

/// Implements the logic for a metal view used by MetalView.
protocol MetalViewRenderer: MTKViewDelegate {
    init(metalView: MTKView)
}

/// Renders an MTKView with the given renderer class.
struct MetalView<R: MetalViewRenderer>: View {
    @State private var metalView = MTKView()
    @State private var renderer: R?

    var body: some View {
        MetalViewRepresentable(metalView: $metalView)
          .onAppear { renderer = R(metalView: metalView) }
    }
}

fileprivate struct MetalViewRepresentable: NSViewRepresentable {
    @Binding var metalView: MTKView

    func makeNSView(context: Context) -> some NSView {
        metalView
    }
    
    func updateNSView(_ view: NSViewType, context: Context) {
        updateMetalView()
    }

    func updateMetalView() {
    }
}
