import CoreGraphics
import Foundation

let display = CGMainDisplayID()
guard let modes = CGDisplayCopyAllDisplayModes(display, nil) as? [CGDisplayMode], !modes.isEmpty else {
    fputs("no display modes\n", stderr)
    exit(1)
}

var seen = Set<String>()
for mode in modes {
    let key = "\(mode.width)x\(mode.height)"
    if seen.insert(key).inserted {
        print("mode \(key) pixels \(mode.pixelWidth)x\(mode.pixelHeight) hz \(mode.refreshRate)")
    }
}

func area(_ mode: CGDisplayMode) -> Int { mode.width * mode.height }

let preferred = modes.filter { $0.width == 1440 && $0.height == 900 }
let large = modes.filter { $0.width >= 1440 && $0.height >= 900 }
let minimum = modes.filter { $0.width >= 1280 && $0.height >= 800 }
let chosen = preferred.first ?? large.max(by: { area($0) < area($1) }) ?? minimum.max(by: { area($0) < area($1) })

guard let chosen else {
    fputs("no mode at least 1280x800\n", stderr)
    exit(2)
}

var config: CGDisplayConfigRef?
guard CGBeginDisplayConfiguration(&config) == .success else { exit(1) }
guard CGConfigureDisplayWithDisplayMode(config, display, chosen, nil) == .success else { exit(1) }
let result = CGCompleteDisplayConfiguration(config, .permanently)
guard result == .success else {
    fputs("failed to set \(chosen.width)x\(chosen.height): \(result.rawValue)\n", stderr)
    exit(1)
}
print("display \(chosen.width)x\(chosen.height)")
