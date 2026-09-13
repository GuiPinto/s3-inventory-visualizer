import AppKit

// Explicit entry point. The implicit `@main` on an NSApplicationDelegate did not deliver
// applicationDidFinishLaunching in this target, so the application is started by hand.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
