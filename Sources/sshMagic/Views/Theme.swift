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
        terminal.nativeForegroundColor = NSColor(srgbRed: 0.85, green: 0.87, blue: 0.91, alpha: 1)
        terminal.installColors(ansiPalette)
    }

    /// 16-colour ANSI palette (a muted "night" scheme). SwiftTerm colour
    /// components are 16-bit (0…65535).
    private static let ansiPalette: [SwiftTerm.Color] = {
        func c(_ r: Int, _ g: Int, _ b: Int) -> SwiftTerm.Color {
            SwiftTerm.Color(red: UInt16(r * 257), green: UInt16(g * 257), blue: UInt16(b * 257))
        }
        return [
            c(0x1b, 0x1d, 0x24),  // black
            c(0xe0, 0x6c, 0x75),  // red
            c(0x98, 0xc3, 0x79),  // green
            c(0xe5, 0xc0, 0x7b),  // yellow
            c(0x61, 0xaf, 0xef),  // blue
            c(0xc6, 0x78, 0xdd),  // magenta
            c(0x56, 0xb6, 0xc2),  // cyan
            c(0xab, 0xb2, 0xbf),  // white
            c(0x5c, 0x63, 0x70),  // bright black
            c(0xe0, 0x6c, 0x75),  // bright red
            c(0x98, 0xc3, 0x79),  // bright green
            c(0xe5, 0xc0, 0x7b),  // bright yellow
            c(0x61, 0xaf, 0xef),  // bright blue
            c(0xc6, 0x78, 0xdd),  // bright magenta
            c(0x56, 0xb6, 0xc2),  // bright cyan
            c(0xff, 0xff, 0xff),  // bright white
        ]
    }()
}
