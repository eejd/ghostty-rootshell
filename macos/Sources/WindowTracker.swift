import SwiftUI

/// This modifier tracks whether the window is the key window in the isKeyWindow environment value.
struct WindowObservationModifier: ViewModifier {
    @StateObject var windowObserver: WindowObserver = WindowObserver()
    
    func body(content: Content) -> some View {
        content.background(
            HostingWindowFinder { [weak windowObserver] window in
                windowObserver?.window = window
            }
        ).environment(\.isKeyWindow, windowObserver.isKeyWindow)
    }
}

extension EnvironmentValues {
    struct IsKeyWindowKey: EnvironmentKey {
        static var defaultValue: Bool = false
        typealias Value = Bool
    }
    
    fileprivate(set) var isKeyWindow: Bool {
        get {
            self[IsKeyWindowKey.self]
        }
        set {
            self[IsKeyWindowKey.self] = newValue
        }
    }
}

class WindowObserver: ObservableObject {
    @Published public private(set) var isKeyWindow: Bool = false
    
    private var becomeKeyobserver: NSObjectProtocol?
    private var resignKeyobserver: NSObjectProtocol?

    weak var window: NSWindow? {
        didSet {
            self.isKeyWindow = window?.isKeyWindow ?? false
            guard let window = window else {
                self.becomeKeyobserver = nil
                self.resignKeyobserver = nil
                return
            }
            
            self.becomeKeyobserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { (n) in
                self.isKeyWindow = true
            }
            
            self.resignKeyobserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { (n) in
                self.isKeyWindow = false
            }
        }
    }
}

/// This view calls the callback with the window value that hosts the view.
struct HostingWindowFinder: NSViewRepresentable {
    var callback: (NSWindow?) -> ()

    func makeNSView(context: Self.Context) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        DispatchQueue.main.async { [weak view] in
            self.callback(view?.window)
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
}
