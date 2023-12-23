import Cocoa

/// The state stored for terminal window restoration.
class TerminalRestorableState: NSObject, NSSecureCoding {
    public static var supportsSecureCoding = true
    
    static let coderKey = "state"
    static let versionKey = "version"
    static let version: Int = 1
    
    override init() {
        super.init()
    }
    
    required init?(coder aDecoder: NSCoder) {
        // If the version doesn't match then we can't decode. In the future we can perform
        // version upgrading or something but for now we only have one version so we
        // don't bother.
        guard aDecoder.decodeInteger(forKey: Self.versionKey) == Self.version else {
            return nil
        }
    }
    
    func encode(with coder: NSCoder) {
        coder.encode(Self.version, forKey: Self.versionKey)
        coder.encode(self, forKey: Self.coderKey)
    }
}

/// The NSWindowRestoration implementation that is called when a terminal window needs to be restored.
/// The encoding of a terminal window is handled elsewhere (usually NSWindowDelegate).
class TerminalWindowRestoration: NSObject, NSWindowRestoration {
    enum RestoreError: Error {
        case delegateInvalid
        case identifierUnknown
        case stateDecodeFailed
        case windowDidNotLoad
    }
    
    static func restoreWindow(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        state: NSCoder,
        completionHandler: @escaping (NSWindow?, Error?) -> Void
    ) {
        // Verify the identifier is what we expect
        guard identifier == .init(String(describing: Self.self)) else {
            completionHandler(nil, RestoreError.identifierUnknown)
            return
        }
        
        // Decode the state. If we can't decode the state, then we can't restore.
        guard let state = TerminalRestorableState(coder: state) else {
            completionHandler(nil, RestoreError.stateDecodeFailed)
            return
        }
        
        // The app delegate is definitely setup by now. If it isn't our AppDelegate
        // then something is royally fucked up but protect against it anyhow.
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else {
            completionHandler(nil, RestoreError.delegateInvalid)
            return
        }
        
        // The window creation has to go through our terminalManager so that it
        // can be found for events from libghostty. This uses the low-level
        // createWindow so that AppKit can place the window wherever it should
        // be.
        let c = appDelegate.terminalManager.createWindow(withBaseConfig: nil)
        guard let window = c.window else {
            completionHandler(nil, RestoreError.windowDidNotLoad)
            return
        }
        
        completionHandler(window, nil)
        AppDelegate.logger.warning("state RESTORE")
    }
}
