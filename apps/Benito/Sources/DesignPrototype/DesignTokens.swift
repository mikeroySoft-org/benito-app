import BenitoKit
import SwiftUI

/// Benito design tokens — OpenBBQ layout grammar (gutter/thumb/radius/cards)
/// with a warm night-care palette that follows the OS light/dark setting.
enum DesignTokens {
    // Backgrounds (OpenBBQ canvas grammar) — adaptive; see `BenitoPalette`.
    static let bgCanvas = BenitoPalette.canvas
    static let bgCard = BenitoPalette.card
    static let bgCardElevated = BenitoPalette.cardElevated

    // Text
    static let textPrimary = BenitoPalette.textPrimary
    static let textSecondary = BenitoPalette.textSecondary
    static let textTertiary = BenitoPalette.textTertiary
    /// Text / icons sitting on a solid accent fill (selected chips, primary CTAs).
    static let onAccent = BenitoPalette.onAccent

    // Domain accents
    static let feed = BenitoPalette.feed            // coral — breast/bottle
    static let diaper = BenitoPalette.diaper        // amber
    static let sleep = BenitoPalette.sleep          // teal
    static let active = BenitoPalette.active        // running timer / awake ok
    static let fault = BenitoPalette.fault
    static let accentBlue = BenitoPalette.accentBlue // primary save CTAs
    static let bottle = BenitoPalette.bottle        // lilac bottle chip
    static let medicine = BenitoPalette.medicine    // green — meds / dose
    static let outing = BenitoPalette.outing        // orchid — walks / car rides
    static let crying = BenitoPalette.crying        // olive — crying spells (mood)

    /// Accent for an `activity` span (outing or crying).
    static func accent(for kind: ActivityKind) -> Color { BenitoPalette.accent(for: kind) }

    // Layout (match OpenBBQ Cook HUD)
    static let thumbMin: CGFloat = 52
    /// Taller tap target for two-line choice rows (onboarding).
    static let thumbMinTall: CGFloat = 72
    static let gutter: CGFloat = 16
    static let cardRadius: CGFloat = 14
    static let chipRadius: CGFloat = 100
    /// Max width for Home / Log / Account content and the bottom dock on wide windows.
    static let readableContentWidth: CGFloat = 640
}
