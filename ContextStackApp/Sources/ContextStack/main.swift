import AppKit

if CommandLine.arguments.contains("--ranker-selftest") {
    RankerSelfTest.run()
}
if CommandLine.arguments.contains("--doc-selftest") {
    DocSelfTest.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
