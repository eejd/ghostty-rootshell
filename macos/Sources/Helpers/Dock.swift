import Cocoa

// Private API to get Dock location
@_silgen_name("CoreDockGetOrientationAndPinning")
func CoreDockGetOrientationAndPinning(
    _ outOrientation: UnsafeMutablePointer<Int32>,
    _ outPinning: UnsafeMutablePointer<Int32>)

// Private API to get the current Dock auto-hide state
@_silgen_name("CoreDockGetAutoHideEnabled")
func CoreDockGetAutoHideEnabled() -> Bool

enum DockOrientation: Int {
    case top = 1
    case bottom = 2
    case left = 3
    case right = 4
}

class Dock {
    /// Returns the orientation of the dock or nil if it can't be determined.
    static var orientation: DockOrientation? {
        var orientation: Int32 = 0
        var pinning: Int32 = 0
        CoreDockGetOrientationAndPinning(&orientation, &pinning)
        return .init(rawValue: Int(orientation)) ?? nil
    }

    /// Returns true if the dock has auto-hide enabled.
    static var autoHideEnabled: Bool {
        return CoreDockGetAutoHideEnabled()
    }
}
