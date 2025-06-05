import AppKit

/// A target object for UndoManager that automatically expires after a specified duration.
/// 
/// ExpiringTarget holds a reference to a target object and removes all undo actions
/// associated with itself from the UndoManager when the timer expires. This is useful
/// for creating temporary undo operations that should not persist beyond a certain time.
///
/// The parameter T can be used to retain a reference to some target value
/// that can be used in the undo operation. The target is released when the timer expires.
///
/// - Parameter T: The type of the target object, constrained to AnyObject
class ExpiringTarget<T: AnyObject> {
    private(set) var target: T?
    private var timer: Timer?
    private weak var undoManager: UndoManager?

    /// Creates an expiring target that will automatically remove undo actions after the specified duration.
    ///
    /// - Parameters:
    ///   - target: The target object to hold weakly. Defaults to nil.
    ///   - duration: The time after which the target should expire
    ///   - undoManager: The UndoManager from which to remove actions when expired
    init(_ target: T? = nil, with duration: Duration, in undoManager: UndoManager) {
        self.target = target
        self.undoManager = undoManager
        self.timer = Timer.scheduledTimer(
            withTimeInterval: duration.timeInterval,
            repeats: false) { _ in
            self.expire()
        }
    }
    
    /// Manually expires the target, removing all associated undo actions and invalidating the timer.
    /// 
    /// This method is called automatically when the timer fires, but can also be called manually
    /// to expire the target before the timer duration has elapsed.
    func expire() {
        target = nil
        undoManager?.removeAllActions(withTarget: self)
        timer?.invalidate()
    }

    deinit {
        expire()
    }
}

extension ExpiringTarget where T == NSObject {
    convenience init(with duration: Duration, in undoManager: UndoManager) {
        self.init(nil, with: duration, in: undoManager)
    }
}
