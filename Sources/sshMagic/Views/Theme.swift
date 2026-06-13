import AppKit
import SwiftTerm
import SwiftUI

/// Centralized look-and-feel. Keeps the "sexy dark" palette in one place so the
/// SwiftUI chrome and the SwiftTerm surface stay visually consistent.
enum Theme {
    // MARK: SwiftUI chrome
    // SwiftTerm also exports a `Color` type, so qualify these as SwiftUI.Color.
    static let accent = SwiftUI.Color(red: 0.45, green: 0.78, blue: 1.0)  // electric blue
    static let panel = SwiftUI.Color(red: 0.07, green: 0.08, blue: 0.11)  // sidebar / chrome
    static let panelRaised = SwiftUI.Color(red: 0.11, green: 0.12, blue: 0.16)
    static let terminalBG = SwiftUI.Color(red: 0.05, green: 0.05, blue: 0.07)

    static let bonjourTint = SwiftUI.Color(red: 0.45, green: 0.85, blue: 0.6)  // green
    static let scanTint = SwiftUI.Color(red: 0.95, green: 0.75, blue: 0.4)  // amber
    static let manualTint = SwiftUI.Color(red: 0.7, green: 0.6, blue: 0.95)  // violet

    static func tint(for source: HostSource) -> SwiftUI.Color {
        switch source {
        case .bonjour: return bonjourTint
        case .scan: return scanTint
        case .manual: return manualTint
        }
    }

    static func label(for source: HostSource) -> String {
        switch source {
        case .bonjour: return "Bonjour"
        case .scan: return "Scan"
        case .manual: return "Saved"
        }
    }

    // MARK: SwiftTerm surface
    /// Apply fonts + colors to an embedded terminal view.
    static func apply(to terminal: TerminalView) {
        if let mono = NSFont(name: "JetBrainsMono-Regular", size: 13)
            ?? NSFont(name: "SF Mono", size: 13)
        {
            terminal.font = mono
        } else {
            terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        }
        terminal.nativeBackgroundColor = NSColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 1)
        // Brighter foreground so plain output reads crisp, not muddy grey.
        terminal.nativeForegroundColor = NSColor(srgbRed: 0.92, green: 0.94, blue: 0.98, alpha: 1)
        // Bold text uses the brighter palette variants.
        terminal.useBrightColors = true
        // Accent cursor + selection to match the app's electric-blue theme.
        terminal.caretColor = NSColor(srgbRed: 0.45, green: 0.78, blue: 1.0, alpha: 1)
        terminal.selectedTextBackgroundColor = NSColor(srgbRed: 0.45, green: 0.78, blue: 1.0, alpha: 0.30)
        terminal.installColors(ansiPalette)
    }

    /// 16-colour ANSI palette (a muted "night" scheme). SwiftTerm colour
    /// components are 16-bit (0…65535).
    private static let ansiPalette: [SwiftTerm.Color] = {
        func c(_ r: Int, _ g: Int, _ b: Int) -> SwiftTerm.Color {
            SwiftTerm.Color(red: UInt16(r * 257), green: UInt16(g * 257), blue: UInt16(b * 257))
        }
        return [
            // Normal: a vivid take on the One Dark palette.
            c(0x21, 0x25, 0x2b),  // black
            c(0xef, 0x59, 0x6f),  // red
            c(0x89, 0xca, 0x78),  // green
            c(0xe5, 0xc0, 0x7b),  // yellow
            c(0x5c, 0xb3, 0xff),  // blue
            c(0xd5, 0x5f, 0xde),  // magenta
            c(0x48, 0xc6, 0xd8),  // cyan
            c(0xab, 0xb2, 0xbf),  // white
            // Bright: genuinely brighter/more saturated so bold output pops.
            c(0x5c, 0x63, 0x70),  // bright black
            c(0xff, 0x7a, 0x90),  // bright red
            c(0xa6, 0xe2, 0x8c),  // bright green
            c(0xff, 0xe2, 0x8a),  // bright yellow
            c(0x82, 0xc8, 0xff),  // bright blue
            c(0xe6, 0x8a, 0xff),  // bright magenta
            c(0x6c, 0xe0, 0xf0),  // bright cyan
            c(0xff, 0xff, 0xff),  // bright white
        ]
    }()
}
