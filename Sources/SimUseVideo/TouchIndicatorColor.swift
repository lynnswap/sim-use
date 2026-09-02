// SPDX-License-Identifier: Apache-2.0
import AppKit
import ArgumentParser

/// Semantic color choices for recorded touch indicators.
///
/// The names intentionally mirror AppKit's `NSColor.system*` vocabulary.
/// They are resolved once under Aqua when a renderer is created, so recorded
/// output does not depend on the host's current appearance.
public enum TouchIndicatorColor: String, CaseIterable, ExpressibleByArgument, Sendable {
    case blue
    case red
    case orange
    case yellow
    case green
    case mint
    case teal
    case cyan
    case indigo
    case purple
    case pink
    case brown
    case gray

    fileprivate var appKitColor: NSColor {
        switch self {
        case .blue: .systemBlue
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .mint: .systemMint
        case .teal: .systemTeal
        case .cyan: .systemCyan
        case .indigo: .systemIndigo
        case .purple: .systemPurple
        case .pink: .systemPink
        case .brown: .systemBrown
        case .gray: .systemGray
        }
    }

    package func resolveSRGB() throws -> ResolvedTouchIndicatorColor {
        guard let aqua = NSAppearance(named: .aqua) else {
            throw TouchIndicatorColorResolutionError.aquaAppearanceUnavailable
        }

        var resolved: NSColor?
        aqua.performAsCurrentDrawingAppearance {
            resolved = appKitColor.usingColorSpace(.sRGB)
        }

        guard let resolved else {
            throw TouchIndicatorColorResolutionError.sRGBConversionFailed(self)
        }

        return ResolvedTouchIndicatorColor(
            red: resolved.redComponent,
            green: resolved.greenComponent,
            blue: resolved.blueComponent
        )
    }
}

enum TouchIndicatorColorResolutionError: Error, LocalizedError, Equatable {
    case aquaAppearanceUnavailable
    case sRGBConversionFailed(TouchIndicatorColor)

    var errorDescription: String? {
        switch self {
        case .aquaAppearanceUnavailable:
            "The Aqua appearance is unavailable, so the touch indicator color cannot be resolved."
        case let .sRGBConversionFailed(color):
            "The semantic touch indicator color '\(color.rawValue)' could not be converted to sRGB."
        }
    }
}

package struct ResolvedTouchIndicatorColor: Equatable, Sendable {
    package let red: CGFloat
    package let green: CGFloat
    package let blue: CGFloat
}
