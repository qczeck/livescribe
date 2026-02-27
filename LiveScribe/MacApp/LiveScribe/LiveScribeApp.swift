import AppKit

// @main designates this as the app entry point regardless of filename.
// LSUIElement=YES in Info.plist hides the app from the Dock.

@main
struct LiveScribeApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
