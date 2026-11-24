import QuadratCore
import SwiftUI

enum QuadratTheme {
    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.11, green: 0.11, blue: 0.12) : Color(red: 0.949, green: 0.949, blue: 0.949)
    }

    static func sidebar(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.133, green: 0.145, blue: 0.192) : Color(red: 0.827, green: 0.875, blue: 0.937)
    }

    static func window(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.09, green: 0.09, blue: 0.10) : Color(red: 0.961, green: 0.961, blue: 0.969)
    }

    static func separator(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }

    static func kind(_ kind: ContentKind, _ scheme: ColorScheme) -> Color {
        let hex: UInt32
        if scheme == .dark {
            switch kind {
            case .developer: hex = 0x0C6AD0
            case .builds: hex = 0x5A58C0
            case .nodeModules: hex = 0x0CABA4
            case .vms: hex = 0x3298C4
            case .photos: hex = 0xE03A58
            case .media: hex = 0xA45ACC
            case .apps: hex = 0xE08810
            case .documents: hex = 0xE0B40C
            case .caches: hex = 0x94785C
            case .backups: hex = 0x2E96A8
            case .system: hex = 0x636366
            case .other: hex = 0x48484A
            case .unscanned: hex = 0x3A3A3C
            }
        } else {
            switch kind {
            case .developer: hex = 0x0E7DF4
            case .builds: hex = 0x6866D2
            case .nodeModules: hex = 0x0EC2BA
            case .vms: hex = 0x3BABDE
            case .photos: hex = 0xF4385B
            case .media: hex = 0xB162D9
            case .apps: hex = 0xF4940E
            case .documents: hex = 0xF4C60E
            case .caches: hex = 0xA68C6D
            case .backups: hex = 0x39ADC2
            case .system: hex = 0x8E8E93
            case .other: hex = 0xB1B1B6
            case .unscanned: hex = 0xD0D0D4
            }
        }
        return Color(hex: hex)
    }

    static let legendOrder: [ContentKind] = [
        .developer, .builds, .nodeModules, .vms, .photos, .media,
        .apps, .documents, .caches, .backups, .system, .other
    ]
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

struct AppMark: View {
    var side: CGFloat = 72

    var body: some View {
        Image("AppMark")
            .resizable()
            .interpolation(.high)
            .frame(width: side, height: side)
            .accessibilityLabel("Quadrat")
    }
}
