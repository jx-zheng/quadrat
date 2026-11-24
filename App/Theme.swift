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
        Color(hex: kindHex(kind, scheme))
    }

    /// Same-kind siblings shift a few percent so they don't read as one flat slab.
    static func varied(_ kind: ContentKind, _ scheme: ColorScheme, variant: UInt32) -> Color {
        let hex = kindHex(kind, scheme)
        let step = Double(Int(variant % 5) - 2) * 0.045
        func channel(_ shift: Int) -> Double {
            let value = Double((hex >> shift) & 0xFF) / 255 + step
            return min(1, max(0, value))
        }
        return Color(red: channel(16), green: channel(8), blue: channel(0))
    }

    private static func kindHex(_ kind: ContentKind, _ scheme: ColorScheme) -> UInt32 {
        if scheme == .dark {
            switch kind {
            case .developer: return 0x0C6AD0
            case .builds: return 0x5A58C0
            case .nodeModules: return 0x0CABA4
            case .vms: return 0x3298C4
            case .photos: return 0xE03A58
            case .media: return 0xA45ACC
            case .apps: return 0xE08810
            case .documents: return 0xE0B40C
            case .caches: return 0x94785C
            case .backups: return 0x2E96A8
            case .system: return 0x636366
            case .other: return 0x48484A
            case .unscanned: return 0x3A3A3C
            }
        }
        switch kind {
        case .developer: return 0x0E7DF4
        case .builds: return 0x6866D2
        case .nodeModules: return 0x0EC2BA
        case .vms: return 0x3BABDE
        case .photos: return 0xF4385B
        case .media: return 0xB162D9
        case .apps: return 0xF4940E
        case .documents: return 0xF4C60E
        case .caches: return 0xA68C6D
        case .backups: return 0x39ADC2
        case .system: return 0x8E8E93
        case .other: return 0xB1B1B6
        case .unscanned: return 0xD0D0D4
        }
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
