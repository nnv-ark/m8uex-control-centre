import SwiftUI
import AppKit

// MARK: - Design tokens

/// The app's colours, in two appearances.
///
/// The art direction is a warm amber instrument panel — the industrial orange of
/// a piece of test equipment — with the M8U eX front panel's green (input) and red
/// (output) LEDs sitting on top of it.
///
/// Every colour here is *dynamic*: it resolves against the appearance in effect,
/// so the app follows the system setting rather than ignoring it. Hard-coding dark
/// values is what previously produced near-black text on a dark panel whenever the
/// Mac was set to Light mode.
public enum Palette {

    // MARK: Adaptive colour

    /// Builds a colour that resolves differently in Light and Dark.
    ///
    /// The switch happens inside AppKit's colour resolution rather than at
    /// view-build time, which is what makes this work everywhere — including
    /// `.foregroundStyle` and `.fill`, where a plain ternary on the environment
    /// would not survive into the render pass.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return nsColor(hex: isDark ? dark : light)
        })
    }

    private static func nsColor(hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }

    // MARK: Surfaces

    /// The window background behind everything.
    public static let windowBackground = adaptive(light: 0xFDF3E3, dark: 0x231409)
    /// A panel sitting on the window background.
    public static let panel = adaptive(light: 0xFFFFFF, dark: 0x301D0F)
    /// A slightly raised surface: the status header, editor wells.
    public static let panelRaised = adaptive(light: 0xFFF8EC, dark: 0x3B2413)
    /// Hairline borders and dividers.
    public static let stroke = adaptive(light: 0xE0C9A6, dark: 0x5C3A21)

    // MARK: Text

    /// Body text on the app's own surfaces.
    public static let text = adaptive(light: 0x3A2408, dark: 0xF7E8D2)
    /// Muted text: subtitles, units, secondary labels.
    public static let mutedText = adaptive(light: 0x6B4A25, dark: 0xDCC3A4)
    /// The quietest text: hints and tertiary annotations.
    public static let faintText = adaptive(light: 0x8A6B45, dark: 0xBCA184)

    // MARK: Accent and state

    /// Interactive accent: selection, links, structural highlights.
    public static let accent = adaptive(light: 0x0B5FAE, dark: 0x7FB6FF)

    // MARK: Front-panel LEDs
    //
    // Deliberately the same hue in both appearances, with only the lightness
    // adjusted to stay legible: these two colours *are* the hardware's meaning —
    // green is an input, red is an output — so they must not change meaning
    // between appearances.

    /// A socket working as an input. Green, as on the front panel.
    public static let input = adaptive(light: 0x1B7A38, dark: 0x38D96B)
    /// A socket working as an output. Red, as on the front panel.
    public static let output = adaptive(light: 0xBE2A20, dark: 0xFB4A40)
    /// A socket with no traffic yet, so its direction is unknown.
    public static let idle = adaptive(light: 0x9A8574, dark: 0x8A7565)

    // MARK: Subtle fills
    //
    // Tints that read as "slightly lifted" or "slightly sunken" against a surface.
    // In Dark mode that means adding white; in Light mode, adding shadow.

    /// A faint lift, for track backgrounds and unselected markers.
    public static let subtleFill = adaptive(light: 0xEFE0C9, dark: 0x4A3020)
    /// A stronger lift, for a filled cell or well.
    public static let strongFill = adaptive(light: 0xE0C9A6, dark: 0x5E3D22)
    /// A sunken well, for meter tracks and monitor rows.
    public static let sunkenFill = adaptive(light: 0xEADCC6, dark: 0x1A0E05)
    /// A translucent dark scrim, for toasts.
    public static let scrim = Color.black.opacity(0.78)

    // MARK: Geometry

    /// Corner radius shared by every card and control.
    public static let cornerRadius: CGFloat = 8

    /// The LED colour for a direction, matching the hardware front panel.
    public static func color(for direction: PortDirection) -> Color {
        switch direction {
        case .input: return input
        case .output: return output
        case .idle: return idle
        }
    }
}

// MARK: - Text styles

extension View {
    /// Applies the app's body text colour, which adapts to the appearance.
    public func bodyText() -> some View {
        foregroundStyle(Palette.text)
    }

    /// Applies the muted text colour that is legible on the app's panels.
    ///
    /// Prefer this to `.foregroundStyle(.secondary)`: the semantic style is tuned
    /// for macOS's own chrome and measured as low as 1.34:1 on these surfaces.
    public func mutedText() -> some View {
        foregroundStyle(Palette.mutedText)
    }

    /// Applies the quietest legible text colour.
    public func faintText() -> some View {
        foregroundStyle(Palette.faintText)
    }
}

// MARK: - LED

/// A single front-panel-style indicator lamp.
public struct LED: View {
    public var direction: PortDirection
    public var lit: Bool
    public var size: CGFloat

    public init(direction: PortDirection, lit: Bool = true, size: CGFloat = 10) {
        self.direction = direction
        self.lit = lit
        self.size = size
    }

    public var body: some View {
        let base = Palette.color(for: direction)
        let active = lit && direction != .idle
        Circle()
            .fill(active ? base : base.opacity(0.3))
            .overlay(
                Circle().strokeBorder(Palette.stroke, lineWidth: 0.5)
            )
            .shadow(color: active ? base.opacity(0.7) : .clear, radius: active ? size * 0.45 : 0)
            .frame(width: size, height: size)
            .animation(.easeOut(duration: 0.12), value: direction)
    }
}

// MARK: - Activity meter

/// A horizontal level bar showing smoothed message throughput for one port.
public struct ActivityMeter: View {
    public var level: Double
    public var peak: Double
    public var direction: PortDirection
    public var height: CGFloat

    public init(level: Double, peak: Double, direction: PortDirection, height: CGFloat = 5) {
        self.level = level
        self.peak = peak
        self.direction = direction
        self.height = height
    }

    public var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            // A slight curve makes quiet traffic visible without flattening loud traffic.
            let shaped = pow(max(0, min(1, level)), 0.6)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(Palette.sunkenFill)
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(Palette.color(for: direction).opacity(0.9))
                    .frame(width: max(0, width * shaped))
                if peak > 0.01 {
                    Rectangle()
                        .fill(Palette.color(for: direction))
                        .frame(width: 2, height: height)
                        .offset(x: max(0, min(width - 2, width * peak - 1)))
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - Small labelled value

/// A compact "LABEL / value" block used throughout the inspectors.
public struct StatBlock: View {
    public var title: String
    public var value: String
    public var tint: Color?

    public init(_ title: String, value: String, tint: Color? = nil) {
        self.title = title
        self.value = value
        self.tint = tint
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .mutedText()
                .kerning(0.5)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(tint ?? Palette.text)
                .lineLimit(1)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Channel strip

/// Sixteen small channel indicators, used to show which channels a port or
/// route is carrying.
public struct ChannelStrip: View {
    public var mask: UInt16
    public var dimmedWhenClear: Bool

    public init(mask: UInt16, dimmedWhenClear: Bool = true) {
        self.mask = mask
        self.dimmedWhenClear = dimmedWhenClear
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<16, id: \.self) { index in
                let on = mask & (1 << UInt16(index)) != 0
                RoundedRectangle(cornerRadius: 1)
                    .fill(on ? Palette.accent : Palette.subtleFill.opacity(dimmedWhenClear ? 0.85 : 0.45))
                    .frame(width: 6, height: 12)
            }
        }
    }
}

// MARK: - Section card

/// A titled container with a consistent background, used for every panel.
public struct Panel<Content: View>: View {
    public var title: String?
    public var subtitle: String?
    @ViewBuilder public var content: () -> Content

    public init(title: String? = nil, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .bodyText()
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .mutedText()
                    }
                }
            }
            content()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Palette.cornerRadius)
                .fill(Palette.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Palette.cornerRadius)
                .strokeBorder(Palette.stroke.opacity(0.8), lineWidth: 1)
        )
    }
}

// MARK: - Empty state

public struct EmptyStateView: View {
    public var symbol: String
    public var title: String
    public var message: String

    public init(symbol: String, title: String, message: String) {
        self.symbol = symbol
        self.title = title
        self.message = message
    }

    public var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .faintText()
            Text(title)
                .font(.headline)
                .bodyText()
            Text(message)
                .font(.callout)
                .mutedText()
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Formatting helpers

public enum Format {
    /// Message rates read better as whole numbers with a thousands separator.
    public static func rate(_ value: Double) -> String {
        if value < 0.05 { return "—" }
        if value < 10 { return String(format: "%.1f/s", value) }
        return "\(Int(value.rounded()).formatted())/s"
    }

    public static func count(_ value: UInt64) -> String {
        value.formatted(.number.notation(.compactName))
    }

    public static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    /// A clock-style timestamp for the monitor, relative to app launch.
    public static func elapsed(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let minutes = Int(total) / 60
        let secs = total - Double(minutes * 60)
        return String(format: "%02d:%06.3f", minutes, secs)
    }

    /// Hex dump of a message, the way a MIDI monitor traditionally shows bytes.
    public static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
