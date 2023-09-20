import AppKit
import Cocoa

// We put the GHOSTTY_MAC_APP env var into the Info.plist to detect
// whether we launch from the app or not. A user can fake this if
// they want but they're doing so at their own detriment...
let process = ProcessInfo.processInfo
if (process.environment["GHOSTTY_MAC_APP"] == "") {
    AppDelegate.logger.warning("NOT IN THE MAC APP")
}

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
