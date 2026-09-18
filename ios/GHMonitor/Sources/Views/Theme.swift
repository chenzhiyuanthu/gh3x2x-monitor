import SwiftUI

enum Theme {
    static let backgroundTop = Color(red: 0.118, green: 0.129, blue: 0.149)     // #1E2126
    static let backgroundBottom = Color(red: 0.086, green: 0.094, blue: 0.106)  // #16181B
    static let card = Color(red: 0.133, green: 0.149, blue: 0.169)              // #22262B
    static let cardBorder = Color.white.opacity(0.04)
    static let textPrimary = Color(red: 0.925, green: 0.933, blue: 0.945)
    static let textSecondary = Color(red: 0.616, green: 0.643, blue: 0.671)
    static let textTertiary = Color(red: 0.45, green: 0.48, blue: 0.51)
    static let blue = Color(red: 0.29, green: 0.55, blue: 0.93)
    static let blueSoft = Color(red: 0.29, green: 0.55, blue: 0.93).opacity(0.35)
    static let green = Color(red: 0.30, green: 0.84, blue: 0.55)
    static let greenBackground = Color(red: 0.12, green: 0.24, blue: 0.21)
    static let amber = Color(red: 0.98, green: 0.72, blue: 0.25)
    static let amberBackground = Color(red: 0.27, green: 0.22, blue: 0.10)
    static let red = Color(red: 0.95, green: 0.35, blue: 0.35)
    static let redBackground = Color(red: 0.27, green: 0.12, blue: 0.12)
    static let grid = Color.white.opacity(0.055)
    static let zoneOff = Color.white.opacity(0.10)

    static func label(_ size: CGFloat = 12) -> Font { .system(size: size, weight: .bold) }
    static func value(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy) }
    static func unit(_ size: CGFloat = 20) -> Font { .system(size: size, weight: .semibold) }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(Theme.label(12))
            .tracking(2.2)
            .foregroundStyle(Theme.textSecondary)
    }
}

/// The green "✓ within a - b" pill (amber / red when the value is out of range).
struct RangePill: View {
    enum Status { case within, above, below, pending }
    let status: Status
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
            Text(text)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(bg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var icon: String {
        switch status {
        case .within: return "checkmark"
        case .above: return "arrow.up"
        case .below: return "arrow.down"
        case .pending: return "ellipsis"
        }
    }
    private var fg: Color {
        switch status {
        case .within: return Theme.green
        case .above, .below: return Theme.amber
        case .pending: return Theme.textTertiary
        }
    }
    private var bg: Color {
        switch status {
        case .within: return Theme.greenBackground
        case .above, .below: return Theme.amberBackground
        case .pending: return Color.white.opacity(0.06)
        }
    }

    static func make(value: Double?, range: MetricRange, pendingText: String = "collecting…") -> RangePill {
        guard let v = value else { return RangePill(status: .pending, text: pendingText) }
        if range.contains(v) { return RangePill(status: .within, text: "within \(range.text)") }
        if v > range.high { return RangePill(status: .above, text: "above \(range.text)") }
        return RangePill(status: .below, text: "below \(range.text)")
    }
}

struct MetricCard<Pill: View>: View {
    let icon: String
    let title: String
    let value: String
    let unit: String
    let valueSize: CGFloat
    @ViewBuilder let pill: () -> Pill

    init(icon: String, title: String, value: String, unit: String, valueSize: CGFloat = 37, @ViewBuilder pill: @escaping () -> Pill) {
        self.icon = icon; self.title = title; self.value = value; self.unit = unit; self.valueSize = valueSize; self.pill = pill
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 22)
                Text(title.uppercased())
                    .font(Theme.label(10.5))
                    .kerning(1.3)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
            }
            .padding(.bottom, 16)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(Theme.value(valueSize))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
                Text(unit)
                    .font(Theme.unit(18))
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.bottom, 12)
            pill()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.cardBorder, lineWidth: 1))
    }
}
