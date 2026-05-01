import SwiftUI

// MARK: - Legacy Color Compatibility
// Keeps older views compiling while we migrate everything to PLThemeStore / palette.
// These are NOT "liquid glass" materials — just solid/fixed colors.

extension Color {
    static let paperlinkOrange = Color(red: 0.98, green: 0.74, blue: 0.38)
    static let paperlinkCanvas = Color(red: 0.98, green: 0.85, blue: 0.62)
    static let paperlinkAccent = Color(red: 0.38, green: 0.76, blue: 0.80)
    static let paperlinkRailButton = Color.white.opacity(0.35)
    static let paperlinkCard = Color.white.opacity(0.22)
}
