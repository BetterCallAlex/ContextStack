import AppKit

if CommandLine.arguments.contains("--ranker-selftest") {
    RankerSelfTest.run()
}
if CommandLine.arguments.contains("--doc-selftest") {
    DocSelfTest.run()
}
if let i = CommandLine.arguments.firstIndex(of: "--render-icon"),
   CommandLine.arguments.count > i + 1 {
    IconKit.renderIconset(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
