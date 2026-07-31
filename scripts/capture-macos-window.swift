import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2,
      let processId = Int32(CommandLine.arguments[1])
else {
    fputs("usage: capture-macos-window.swift <process-id>\n", stderr)
    exit(64)
}

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windowList =
    CGWindowListCopyWindowInfo(options, kCGNullWindowID)
    as? [[String: Any]] ?? []

for window in windowList {
    let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
    let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue
    let number = (window[kCGWindowNumber as String] as? NSNumber)?.intValue
    let bounds = window[kCGWindowBounds as String] as? [String: Any]
    let width = (bounds?["Width"] as? NSNumber)?.doubleValue ?? 0
    let height = (bounds?["Height"] as? NSNumber)?.doubleValue ?? 0

    if owner == processId, layer == 0, width >= 320, height >= 240,
       let number
    {
        print(number)
        exit(0)
    }
}

fputs("no visible application window found for process \(processId)\n", stderr)
exit(2)
