import CoreGraphics
import Foundation

let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
var best: (id: Int, area: CGFloat, rect: String)?
for window in info {
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    let layer = window[kCGWindowLayer as String] as? Int ?? 0
    guard owner == "Quadrat", layer == 0 else { continue }
    guard let number = window[kCGWindowNumber as String] as? Int,
          let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
          let x = bounds["X"], let y = bounds["Y"],
          let width = bounds["Width"], let height = bounds["Height"] else { continue }
    let area = width * height
    if best == nil || area > best!.area {
        best = (number, area, "\(Int(x)),\(Int(y)),\(Int(width)),\(Int(height))")
    }
}
guard let best else { exit(1) }
print(best.rect)
print(best.id)
exit(0)
