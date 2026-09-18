import SwiftUI

/// Heart-rate trend on a grid with a dashed cursor at "now" — the WHOOP Health Monitor look.
struct HeartRateChart: View {
    let points: [HRPoint]
    let window: TimeInterval      // seconds shown across the chart
    let live: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Canvas { g, size in
                let now = ctx.date
                let cursorX = size.width - 26
                // Trend line
                let recent = points.filter { now.timeIntervalSince($0.time) <= window }
                if recent.count >= 2 {
                    let values = recent.map(\.bpm)
                    let lo = max(30, (values.min() ?? 60) - 12)
                    let hi = max(lo + 30, (values.max() ?? 90) + 12)
                    func pt(_ p: HRPoint) -> CGPoint {
                        let x = cursorX - CGFloat(now.timeIntervalSince(p.time) / window) * cursorX
                        let y = 14 + (size.height - 28) * CGFloat(1 - (p.bpm - lo) / (hi - lo))
                        return CGPoint(x: x, y: y)
                    }
                    var path = Path()
                    for (i, p) in recent.enumerated() {
                        if i == 0 { path.move(to: pt(p)) } else { path.addLine(to: pt(p)) }
                    }
                    // extend to the cursor with the latest value
                    if let last = recent.last {
                        path.addLine(to: CGPoint(x: cursorX, y: pt(last).y))
                    }
                    var glow = g
                    glow.addFilter(.blur(radius: 6))
                    glow.stroke(path, with: .color(Theme.blueSoft), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                    g.stroke(path, with: .color(Theme.blue), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                    if let last = recent.last {
                        let c = CGPoint(x: cursorX, y: pt(last).y)
                        g.fill(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)), with: .color(.white))
                        if live {
                            g.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(Theme.blue))
                        }
                    }
                }
                // Dashed cursor
                var cursor = Path()
                cursor.move(to: CGPoint(x: cursorX, y: 0))
                cursor.addLine(to: CGPoint(x: cursorX, y: size.height))
                g.stroke(cursor, with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            }
        }
    }
}

/// Faint square grid drawn behind the whole heart-rate section.
struct GridBackground: View {
    var spacing: CGFloat = 14.5
    var body: some View {
        Canvas { g, size in
            var p = Path()
            var x: CGFloat = 0
            while x <= size.width { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)); x += spacing }
            var y: CGFloat = 0
            while y <= size.height { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)); y += spacing }
            g.stroke(p, with: .color(Theme.grid), lineWidth: 1)
        }
        .mask(
            LinearGradient(colors: [.black, .black, .black.opacity(0.15)], startPoint: .top, endPoint: .bottom)
        )
    }
}

struct ZoneBar: View {
    let zone: Int
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(i < zone ? Theme.blue : Theme.zoneOff)
                    .frame(width: 18, height: 3)
            }
        }
    }
}
