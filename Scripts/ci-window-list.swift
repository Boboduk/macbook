// Prints "<window number> <layer> <width>x<height>" for every on-screen
// window of a process. Used by ci-smoke-test.sh to capture the island panel
// alone (with transparency) via `screencapture -l`.
import CoreGraphics
import Foundation

guard CommandLine.arguments.count > 1, let pid = Int(CommandLine.arguments[1]) else {
    FileHandle.standardError.write("usage: ci-window-list <pid>\n".data(using: .utf8)!)
    exit(2)
}
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows where (window[kCGWindowOwnerPID as String] as? Int) == pid {
    let number = window[kCGWindowNumber as String] as? Int ?? 0
    let layer = window[kCGWindowLayer as String] as? Int ?? 0
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = (bounds["Width"] as? Double).map { Int($0) } ?? 0
    let height = (bounds["Height"] as? Double).map { Int($0) } ?? 0
    print("\(number) \(layer) \(width)x\(height)")
}
