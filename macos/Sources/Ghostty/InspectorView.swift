import Foundation
import MetalKit
import SwiftUI
import GhosttyKit

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
                InspectorViewRepresentable(surfaceView: surfaceView)
            })
        }
    }
    
    struct InspectorViewRepresentable: NSViewRepresentable {
        /// The surface that this inspector represents.
        let surfaceView: SurfaceView

        func makeNSView(context: Context) -> InspectorView {
            let view = InspectorView()
            view.surfaceView = self.surfaceView
            return view
        }

        func updateNSView(_ view: InspectorView, context: Context) {
            view.surfaceView = self.surfaceView
        }
    }
    
    class InspectorView: MTKView {
        let commandQueue: MTLCommandQueue
        
        var surfaceView: SurfaceView? = nil {
            didSet { surfaceViewDidChange() }
        }
        
        private var inspector: ghostty_inspector_t? {
            guard let surfaceView = self.surfaceView else { return nil }
            return surfaceView.inspector
        }
        
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
            self.clearColor = MTLClearColor(red: 0x28 / 0xFF, green: 0x2C / 0xFF, blue: 0x34 / 0xFF, alpha: 1.0)
            
            // Setup our tracking areas for mouse events
            updateTrackingAreas()
        }
        
        required init(coder: NSCoder) {
            fatalError("init(coder:) is not supported for this view")
        }
        
        deinit {
            trackingAreas.forEach { removeTrackingArea($0) }
        }
        
        // MARK: Internal Inspector Funcs
        
        private func surfaceViewDidChange() {
            guard let inspector = self.inspector else { return }
            guard let device = self.device else { return }
            let devicePtr = Unmanaged.passRetained(device).toOpaque()
            ghostty_inspector_metal_init(inspector, devicePtr)
        }
        
        private func updateSize() {
            guard let inspector = self.inspector else { return }

            // Detect our X/Y scale factor so we can update our surface
            let fbFrame = self.convertToBacking(self.frame)
            let xScale = fbFrame.size.width / self.frame.size.width
            let yScale = fbFrame.size.height / self.frame.size.height
            ghostty_inspector_set_content_scale(inspector, xScale, yScale)

            // When our scale factor changes, so does our fb size so we send that too
            ghostty_inspector_set_size(inspector, UInt32(fbFrame.size.width), UInt32(fbFrame.size.height))
        }
        
        // MARK: NSView
        
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
        
        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            updateSize()
        }
        
        override func resize(withOldSuperviewSize oldSize: NSSize) {
            super.resize(withOldSuperviewSize: oldSize)
            updateSize()
        }
        
        // MARK: MTKView
        
        override func draw(_ dirtyRect: NSRect) {
            guard
              let commandBuffer = self.commandQueue.makeCommandBuffer(),
              let descriptor = self.currentRenderPassDescriptor else {
                return
            }
            
            ghostty_inspector_metal_render(
                inspector,
                Unmanaged.passRetained(commandBuffer).toOpaque(),
                Unmanaged.passRetained(descriptor).toOpaque()
            )

            guard let drawable = self.currentDrawable else { return }
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
