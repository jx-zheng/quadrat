import CoreGraphics
import Foundation

let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for window in info {
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    let layer = window[kCGWindowLayer as String] as? Int ?? 0
    guard owner == "Quadrat", layer == 0 else { continue }
    if let number = window[kCGWindowNumber as String] as? Int {
        print(number)
        exit(0)
    }
}
exit(1)
