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
                SurfaceInspector()
            })
        }
    }
    
    struct SurfaceInspector: View {
        var body: some View {
            MetalView<InspectorView>()
        }
    }
    
    class InspectorView: MTKView {
        let commandQueue: MTLCommandQueue
        
        override init(frame: CGRect, device: MTLDevice?) {
            // Initialize our Metal primitives
            guard
              let device = device ?? MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
                fatalError("GPU not available")
            }
            
            // Setup our properties before initializing the parent
            self.commandQueue = commandQueue
            super.init(frame: frame, device: device)
            
            // After initializing the parent we can set our own properties
            self.device = MTLCreateSystemDefaultDevice()
            self.clearColor = MTLClearColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
            
            // Setup our tracking areas for mouse events
            updateTrackingAreas()
        }
        
        required init(coder: NSCoder) {
            fatalError("init(coder:) is not supported for this view")
        }
        
        deinit {
            trackingAreas.forEach { removeTrackingArea($0) }
        }
        
        override func updateTrackingAreas() {
            // To update our tracking area we just recreate it all.
            trackingAreas.forEach { removeTrackingArea($0) }

            // This tracking area is across the entire frame to notify us of mouse movements.
            addTrackingArea(NSTrackingArea(
                rect: frame,
                options: [
                    .mouseMoved,
                    
                    // Only send mouse events that happen in our visible (not obscured) rect
                    .inVisibleRect,

                    // We want active always because we want to still send mouse reports
                    // even if we're not focused or key.
                    .activeAlways,
                ],
                owner: self,
                userInfo: nil))
        }
        
        override func draw(_ dirtyRect: NSRect) {
            guard
              let commandBuffer = self.commandQueue.makeCommandBuffer(),
              let descriptor = self.currentRenderPassDescriptor,
              let renderEncoder =
                commandBuffer.makeRenderCommandEncoder(
                  descriptor: descriptor) else {
                return
            }

            renderEncoder.endEncoding()
            guard let drawable = self.currentDrawable else { return }
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
