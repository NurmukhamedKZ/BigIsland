import AppKit

// XCTest/Testing недоступны без Xcode — проверки логики: `swift run BigIsland --selftest`
if CommandLine.arguments.contains("--selftest") {
    selfTest()
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory) // без иконки в Dock
app.run()
