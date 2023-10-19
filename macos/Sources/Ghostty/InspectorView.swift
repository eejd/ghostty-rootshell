import Foundation
import MetalKit
import SwiftUI

extension Ghostty {
    /// InspectableSurface is a type of Surface view that allows an inspector to be attached.
    struct InspectableSurface: View {
        /// Same as SurfaceWrapper, see the doc comments there.
        @ObservedObject var surfaceView: SurfaceView
        var isSplit: Bool = false
        
        var body: some View {
            SplitView(.vertical, left: {
                SurfaceWrapper(surfaceView: surfaceView, isSplit: isSplit)
            }, right: {
                InspectorView()
            })
        }
    }
    
    struct InspectorView: View {
        var body: some View {
            MetalView<Renderer>()
        }
    }
    
    class Renderer: NSObject, MetalViewRenderer {
        let device: MTLDevice
        let commandQueue: MTLCommandQueue
        
        required init(metalView: MTKView) {
            // Initialize our Metal primitives
            guard
              let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
                fatalError("GPU not available")
            }
            
            self.device = device
            self.commandQueue = commandQueue
            super.init()
            
            // Setup the view to point to this renderer
            metalView.device = device
            metalView.delegate = self
            metalView.clearColor = MTLClearColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
        }
    }
}

extension Ghostty.Renderer: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    }

    func draw(in view: MTKView) {
        guard
          let commandBuffer = self.commandQueue.makeCommandBuffer(),
          let descriptor = view.currentRenderPassDescriptor,
          let renderEncoder =
            commandBuffer.makeRenderCommandEncoder(
              descriptor: descriptor) else {
            return
        }

        renderEncoder.endEncoding()
        guard let drawable = view.currentDrawable else { return }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
