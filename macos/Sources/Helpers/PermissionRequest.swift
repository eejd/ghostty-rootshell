import AppKit
import Foundation

/// Displays a permission request dialog with optional caching of user decisions
class PermissionRequest {
    /// Shows a permission request dialog with customizable caching behavior
    /// - Parameters:
    ///   - key: Unique identifier for storing/retrieving cached decisions in UserDefaults
    ///   - message: The message to display in the alert dialog
    ///   - allowText: Custom text for the allow button (defaults to "Allow")
    ///   - allowDuration: If provided, automatically cache "Allow" responses for this duration
    ///   - window: If provided, shows the alert as a sheet attached to this window
    ///   - completion: Called with the user's decision (true for allow, false for deny)
    /// 
    /// Caching behavior:
    /// - If user checks "Remember my decision for one day", both allow/deny are cached for 24 hours
    /// - If allowDuration is provided and user selects allow (without checkbox), decision is cached for that duration
    /// - Cached decisions are automatically returned without showing the dialog
    @MainActor
    static func show(
        _ key: String,
        message: String,
        informative: String = "",
        allowText: String = "Allow",
        allowDuration: Duration? = nil,
        window: NSWindow? = nil,
        completion: @escaping (Bool) -> Void
    ) {
        // Check if we have a stored decision that hasn't expired
        if let storedResult = getStoredResult(for: key) {
            completion(storedResult)
            return
        }
        
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.alertStyle = .informational

        // Add buttons (they appear in reverse order)
        alert.addButton(withTitle: allowText)
        alert.addButton(withTitle: "Don't Allow")

        // Create checkbox for remembering
        let checkbox = NSButton(
            checkboxWithTitle: "Remember my decision for one day",
            target: nil,
            action: nil)
        checkbox.state = .off

        // Set checkbox as accessory view
        alert.accessoryView = checkbox

        // Show the alert
        if let window = window {
            alert.beginSheetModal(for: window) { response in
                handleResponse(response, rememberDecision: checkbox.state == .on, key: key, allowDuration: allowDuration, completion: completion)
            }
        } else {
            let response = alert.runModal()
            handleResponse(response, rememberDecision: checkbox.state == .on, key: key, allowDuration: allowDuration, completion: completion)
        }
    }
    
    /// Handles the alert response and processes caching logic
    /// - Parameters:
    ///   - response: The alert response from the user
    ///   - rememberDecision: Whether the remember checkbox was checked
    ///   - key: The UserDefaults key for caching
    ///   - allowDuration: Optional duration for auto-caching allow responses
    ///   - completion: Completion handler to call with the result
    private static func handleResponse(
        _ response: NSApplication.ModalResponse,
        rememberDecision: Bool,
        key: String,
        allowDuration: Duration?,
        completion: @escaping (Bool) -> Void) {
        
        let result: Bool
        switch response {
        case .alertFirstButtonReturn: // Allow
            result = true
        case .alertSecondButtonReturn: // Don't Allow
            result = false
        default:
            result = false
        }
        
        // Store the result if checkbox is checked or if "Allow" was selected and allowDuration is set
        if rememberDecision {
            storeResult(result, for: key, duration: .seconds(86400))
        } else if result, let allowDuration {
            storeResult(result, for: key, duration: allowDuration)
        }
        
        completion(result)
    }
    
    /// Retrieves a cached permission decision if it hasn't expired
    /// - Parameter key: The UserDefaults key to check
    /// - Returns: The cached decision, or nil if no valid cached decision exists
    private static func getStoredResult(for key: String) -> Bool? {
        let userDefaults = UserDefaults.standard
        guard let data = userDefaults.data(forKey: key),
              let storedPermission = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: StoredPermission.self, from: data) else {
            return nil
        }
        
        if Date() > storedPermission.expiry {
            // Decision has expired, remove stored value
            userDefaults.removeObject(forKey: key)
            return nil
        }
        
        return storedPermission.result
    }
    
    /// Stores a permission decision in UserDefaults with an expiration date
    /// - Parameters:
    ///   - result: The permission decision to store
    ///   - key: The UserDefaults key to store under
    ///   - duration: How long the decision should be cached
    private static func storeResult(_ result: Bool, for key: String, duration: Duration) {
        let expiryDate = Date().addingTimeInterval(duration.timeInterval)
        let storedPermission = StoredPermission(result: result, expiry: expiryDate)
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: storedPermission, requiringSecureCoding: true) {
            let userDefaults = UserDefaults.standard
            userDefaults.set(data, forKey: key)
        }
    }

    /// Internal class for storing permission decisions with expiration dates in UserDefaults
    /// Conforms to NSSecureCoding for safe archiving/unarchiving
    @objc(StoredPermission)
    private class StoredPermission: NSObject, NSSecureCoding {
        static var supportsSecureCoding: Bool = true

        let result: Bool
        let expiry: Date

        init(result: Bool, expiry: Date) {
            self.result = result
            self.expiry = expiry
            super.init()
        }

        required init?(coder: NSCoder) {
            self.result = coder.decodeBool(forKey: "result")
            guard let expiry = coder.decodeObject(of: NSDate.self, forKey: "expiry") as? Date else {
                return nil
            }
            self.expiry = expiry
            super.init()
        }

        func encode(with coder: NSCoder) {
            coder.encode(result, forKey: "result")
            coder.encode(expiry, forKey: "expiry")
        }
    }
}
