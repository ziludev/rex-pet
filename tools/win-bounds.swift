// Prints the RexPet window bounds as "x y width height" (top-left origin).
import CoreGraphics
import Foundation

let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for window in list where (window[kCGWindowOwnerName as String] as? String) == "RexPet" {
    guard let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
    let x = bounds["X"] ?? 0, y = bounds["Y"] ?? 0
    let w = bounds["Width"] ?? 0, h = bounds["Height"] ?? 0
    print(Int(x), Int(y), Int(w), Int(h))
    exit(0)
}
