import AppKit
import CoreText
import SwiftUI

/// The colours and type of the makemvp site, following the Mac's light or dark mode.
enum Theme {
    static let background = adaptive(light: 0xFFFFFF, dark: 0x000000)
    static let foreground = adaptive(light: 0x000000, dark: 0xEDEDED)
    static let muted = adaptive(light: 0x6B6B6B, dark: 0xA1A1A1)
    static let ghost = adaptive(light: 0xC9C9C9, dark: 0x4D4D4D)
    static let pill = adaptive(light: 0xF2F2EF, dark: 0x1A1A1A)
    static let card = adaptive(light: 0xF7F7F5, dark: 0x0F0F0F)
    static let border = translucent()

    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Inter Tight", size: size).weight(weight)
    }

    /// Inter Tight ships inside the app.
    static func registerFont() {
        guard let url = Bundle.main.url(forResource: "InterTight", withExtension: "woff2") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    // SwiftUI can ask for these colours on any thread, so they can't be tied to the main one.
    private nonisolated static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.isDark ? color(dark) : color(light) })
    }

    private nonisolated static func translucent() -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark ? .white.withAlphaComponent(0.12) : .black.withAlphaComponent(0.10)
        })
    }

    private nonisolated static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

private extension NSAppearance {
    nonisolated var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

/// A rounded button like the site's: quiet by default, solid for the main action.
struct PillButtonStyle: ButtonStyle {
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(13, weight: .medium))
            .foregroundStyle(filled ? Theme.background : Theme.foreground)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(filled ? Theme.foreground : Theme.pill, in: .capsule)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(.capsule)
    }
}

/// A thin line between sections.
struct Rule: View {
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// A large page title, set tight like the site's headings.
struct PageTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(Theme.font(28))
            .tracking(-0.8)
    }
}

/// What shows when a page has nothing on it yet.
struct EmptyNote<Action: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(Theme.font(20))
                .tracking(-0.4)
            Text(detail)
                .font(Theme.font(14))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            action
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyNote where Action == EmptyView {
    init(title: String, detail: String) {
        self.init(title: title, detail: detail) { EmptyView() }
    }
}
