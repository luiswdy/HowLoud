//
//  HowLoudTheme.swift
//  HowLoud
//
//  Created by Luis Wu on 11/23/2026.
//  Copyright © 2026 Luis Wu. All rights reserved.
//

import SwiftUI
import UIKit

// MARK: - Material 3-Inspired Adaptive Color Tokens

enum HowLoudColors {
    // Surfaces & Neutrals
    static let background = Color.adaptive(light: 0xF8FAFC, dark: 0x0F1419)
    static let surfaceContainer = Color.adaptive(light: 0xEEF2F6, dark: 0x1A2129)
    static let surfaceContainerHigh = Color.adaptive(light: 0xE2E8F0, dark: 0x252F3A)
    static let onSurface = Color.adaptive(light: 0x0F172A, dark: 0xF1F5F9)
    static let onSurfaceVariant = Color.adaptive(light: 0x64748B, dark: 0x94A3B8)
    static let outlineVariant = Color.adaptive(light: 0xCBD5E1, dark: 0x334155)

    // Primary Brand Accent (Material Blue)
    static let primary = Color.adaptive(light: 0x1A73E8, dark: 0x60A5FA)
    static let onPrimary = Color.adaptive(light: 0xFFFFFF, dark: 0x0B1220)
    static let primaryContainer = Color.adaptive(light: 0xDCEAFE, dark: 0x1E3A5F)
    static let onPrimaryContainer = Color.adaptive(light: 0x0F4C9A, dark: 0xDBEAFE)

    // Error / Pause / Clipping
    static let error = Color.adaptive(light: 0xDC2626, dark: 0xF87171)
    static let errorContainer = Color.adaptive(light: 0xFEE2E2, dark: 0x451A1A)
    static let onErrorContainer = Color.adaptive(light: 0xB91C1C, dark: 0xFCA5A5)

    // Semantic Acoustic Zones (Single Flat Color per Level)
    static let levelSafe = Color.adaptive(light: 0x16A34A, dark: 0x4ADE80)
    static let levelSafeContainer = Color.adaptive(light: 0xDCFCE7, dark: 0x143322)
    static let levelModerate = Color.adaptive(light: 0xD97706, dark: 0xFBBF24)
    static let levelModerateContainer = Color.adaptive(light: 0xFEF3C7, dark: 0x3B2A12)
    static let levelLoud = Color.adaptive(light: 0xDC2626, dark: 0xF87171)
    static let levelLoudContainer = Color.adaptive(light: 0xFEE2E2, dark: 0x451A1A)
}

// MARK: - Spacing & Radius Scale (8 pt Base Grid)

enum HowLoudSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
}

enum HowLoudRadius {
    static let chip: CGFloat = 12
    static let card: CGFloat = 16
    static let fab: CGFloat = 28
}

// MARK: - Acoustic Level Zone

enum SoundLevelZone: Equatable {
    case quiet
    case moderate
    case loud

    static func forDecibels(_ db: Double) -> SoundLevelZone {
        if db >= 85.0 {
            return .loud
        } else if db >= 70.0 {
            return .moderate
        } else {
            return .quiet
        }
    }

    var label: String {
        switch self {
        case .quiet: return "Quiet"
        case .moderate: return "Moderate"
        case .loud: return "Loud"
        }
    }

    var accentColor: Color {
        switch self {
        case .quiet: return HowLoudColors.levelSafe
        case .moderate: return HowLoudColors.levelModerate
        case .loud: return HowLoudColors.levelLoud
        }
    }

    var containerColor: Color {
        switch self {
        case .quiet: return HowLoudColors.levelSafeContainer
        case .moderate: return HowLoudColors.levelModerateContainer
        case .loud: return HowLoudColors.levelLoudContainer
        }
    }
}

// MARK: - Adaptive Hex Helper

private extension Color {
    static func adaptive(light lightHex: UInt32, dark darkHex: UInt32) -> Color {
        Color(uiColor: UIColor { traitCollection in
            let hex = traitCollection.userInterfaceStyle == .dark ? darkHex : lightHex
            return UIColor(hex: hex)
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: alpha)
    }
}
