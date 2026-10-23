import BenitoKit
import SwiftUI
import UIKit

extension Color {
    /// sRGB colour from a 0xRRGGBB literal.
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }

    /// Follows the OS light/dark appearance (and the SwiftUI `colorScheme` environment).
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1
        )
    }
}

/// Shared Benito palette (app + widgets). Dark is the warm night-care HUD; light is a warm
/// cream "paper" variant. Accents are deepened in light so text/icons on cream meet WCAG AA
/// (≥ 4.5:1 on canvas and cards). `onAccent` is the ink for text on solid accent fills.
enum BenitoPalette {
    static let canvas = Color(light: 0xFAF6EF, dark: 0x0B0D10)
    static let card = Color(light: 0xFFFDF9, dark: 0x161A20)
    static let cardElevated = Color(light: 0xEFE8DC, dark: 0x1C222B)

    static let textPrimary = Color(light: 0x1F1A16, dark: 0xF5F7FA)
    static let textSecondary = Color(light: 0x5E564D, dark: 0x9AA3B2)
    static let textTertiary = Color(light: 0x6F665B, dark: 0x858D9B)

    static let feed = Color(light: 0xB23F2C, dark: 0xFF8B7B)
    static let diaper = Color(light: 0x8A5A00, dark: 0xE8B86D)
    static let sleep = Color(light: 0x1D6A80, dark: 0x6BB3C8)
    static let active = Color(light: 0x12744A, dark: 0x3DDC97)
    static let fault = Color(light: 0xC02626, dark: 0xFF4D4D)
    static let accentBlue = Color(light: 0x1D5FC2, dark: 0x4B9BFF)
    static let bottle = Color(light: 0x6549C0, dark: 0xB8A4FF)
    static let medicine = Color(light: 0x2A744C, dark: 0x7DCEA0)
    static let outing = Color(light: 0xA2307F, dark: 0xEE8FD0)
    static let crying = Color(light: 0x56650A, dark: 0xCBE07A)

    /// Accent for an `activity` span: orchid for outings, olive for crying.
    static func accent(for kind: ActivityKind) -> Color {
        kind.isOuting ? outing : crying
    }

    /// Text/icons on a solid accent fill: white on the deep light accents, near-black on
    /// the bright dark accents.
    static let onAccent = Color(light: 0xFFFFFF, dark: 0x0B0D10)
}
