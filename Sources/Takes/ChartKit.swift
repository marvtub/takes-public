import SwiftUI

/// One chart kit for every chart in Takes (2026-10-29, the "Takes chart redesign" canvas).
/// Bars are gray; only the bar that matters gets the accent. The period before is a dashed gray
/// line or a dashed outline, never a second color. A day still running is striped, a day with no
/// reading yet is a dashed outline. Numbers sit on the right on dashed hairlines. The hovered
/// column gets a soft band and a tooltip: a key bar, the value, the date and the change.
/// Every color comes from Theme, so the palettes and dark mode follow.
enum Kit {
    /// A bar that is not the point.
    static var rest: Color { Theme.muted.opacity(0.22) }
    /// The same bar under the pointer.
    static var restHover: Color { Theme.muted.opacity(0.38) }
    /// The period before: dashed lines and outlines.
    static var ghost: Color { Theme.faint.opacity(0.75) }
    /// Behind the hovered column.
    static var band: Color { Theme.hover }
    static var grid: Color { Theme.border }
    static let dash: [CGFloat] = [3, 4]
    /// The right-hand column that holds the axis numbers.
    static let axis: CGFloat = 34

    /// The bar that matters: the color at the top, fading to 55 % at the base.
    static func key(_ c: Color = Theme.accent) -> LinearGradient {
        LinearGradient(colors: [c, c.opacity(0.55)], startPoint: .top, endPoint: .bottom)
    }

    /// Under a line: 22 % at the top, nothing at the base.
    static func area(_ c: Color = Theme.accent) -> LinearGradient {
        LinearGradient(colors: [c.opacity(0.22), c.opacity(0)], startPoint: .top, endPoint: .bottom)
    }

    /// Round steps from 0 to a nice top at or above `hi`: 0, 1k, 2k, 3k, 4k.
    static func ticks(_ hi: Double, count: Int = 4) -> [Double] {
        guard hi > 0 else { return [0, 1] }
        let raw = hi / Double(count)
        let mag = pow(10, floor(log10(raw)))
        let step = [1, 2, 2.5, 5, 10].map { $0 * mag }.first { $0 >= raw } ?? raw
        let n = Int(ceil(hi / step))
        return (0...max(n, 1)).map { Double($0) * step }
    }

    /// Round steps that hold lo...hi when the axis does not start at 0 (a follower count).
    static func ticks(lo: Double, hi: Double, count: Int = 4) -> [Double] {
        guard lo > 0 else { return ticks(hi, count: count) }
        let span = ticks(max(hi - lo, 1), count: count)
        let step = span.count > 1 ? span[1] : 1
        let start = floor(lo / step) * step
        var out = [start]
        while out.last! < hi { out.append(out.last! + step) }
        return out
    }

    /// A line through values on a fixed scale; `slots` points across, so a line can stop early.
    static func line(_ v: [Double], in size: CGSize, lo: Double, hi: Double, slots: Int? = nil) -> Path {
        var p = Path()
        let n = max(slots ?? v.count, v.count)
        guard v.count > 1 else { return p }
        for (i, x) in v.enumerated() {
            let pt = CGPoint(x: size.width * Double(i) / Double(n - 1), y: size.height - size.height * (x - lo) / max(hi - lo, 1e-9))
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        return p
    }

    /// The same line closed down to the base, for the fill under it.
    static func fill(_ v: [Double], in size: CGSize, lo: Double, hi: Double, slots: Int? = nil) -> Path {
        var p = line(v, in: size, lo: lo, hi: hi, slots: slots)
        guard v.count > 1 else { return p }
        let n = max(slots ?? v.count, v.count)
        p.addLine(to: CGPoint(x: size.width * Double(v.count - 1) / Double(n - 1), y: size.height))
        p.addLine(to: CGPoint(x: 0, y: size.height))
        p.closeSubpath()
        return p
    }

    /// 940 · 1.2k · 38k · 1.5M. Whole numbers below 1,000.
    static func short(_ v: Double) -> String {
        let a = abs(v)
        if a >= 1_000_000 { return trim(v / 1_000_000) + "M" }
        if a >= 1_000 { return trim(v / 1_000) + "k" }
        return a < 10 && v.rounded() != v ? String(format: "%.1f", v) : String(Int(v.rounded()))
    }

    private static func trim(_ v: Double) -> String {
        abs(v) >= 10 || v.rounded() == v ? String(Int(v.rounded())) : String(format: "%.1f", v)
    }

    /// "↑ 25%" against the period before. nil when there was nothing before.
    static func change(_ now: Double, _ before: Double) -> String? {
        guard before > 0 else { return nil }
        let p = (now - before) / before * 100
        if abs(p) < 0.5 { return "same" }
        if p >= 100 { return "↑ " + String(format: now / before >= 10 ? "%.0f×" : "%.1f×", now / before) }
        return (p > 0 ? "↑ " : "↓ ") + "\(Int(abs(p).rounded()))%"
    }

    static func tone(_ now: Double, _ before: Double, goodWhenUp: Bool = true) -> DeltaPill.Tone {
        guard before > 0, abs(now - before) / before >= 0.005 else { return .flat }
        return (now > before) == goodWhenUp ? .up : .down
    }
}

/// "↑ 25%" in a soft pill: green when it went the good way, red when not, gray when flat.
struct DeltaPill: View {
    enum Tone { case up, down, flat }
    let text: String
    var tone: Tone = .flat
    var size: CGFloat = 11.5

    /// The change from `before` to `now`; nil when there is nothing to compare.
    init?(now: Double, before: Double, goodWhenUp: Bool = true, size: CGFloat = 11.5) {
        guard let t = Kit.change(now, before) else { return nil }
        self.init(t, tone: Kit.tone(now, before, goodWhenUp: goodWhenUp), size: size)
    }

    init(_ text: String, tone: Tone = .flat, size: CGFloat = 11.5) {
        self.text = text; self.tone = tone; self.size = size
    }

    var body: some View {
        Text(text).font(Theme.sans(size, .semibold)).monospacedDigit()
            .foregroundStyle(tone == .up ? Theme.live : tone == .down ? Theme.danger : Theme.muted)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(tone == .up ? Theme.liveSoft : tone == .down ? Theme.danger.opacity(0.12) : Theme.hover))
            .lineLimit(1).fixedSize()
    }
}

/// A chart card's top: an icon tile, the title in Nunito, one line under it, and room on the right.
struct ChartHeader<Trailing: View>: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: icon).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.accentInk)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accentSoft))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.display(19)).foregroundStyle(Theme.ink).lineLimit(1)
                if let subtitle { Text(subtitle).font(Theme.sans(11.5)).foregroundStyle(Theme.muted).lineLimit(1) }
            }
            Spacer(minLength: 10)
            trailing()
        }
    }
}

extension ChartHeader where Trailing == EmptyView {
    init(icon: String, title: String, subtitle: String? = nil) {
        self.init(icon: icon, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// One big number with its label over it and a change pill beside it.
struct KitNumber: View {
    let label: String
    let value: String
    var pill: DeltaPill? = nil
    var note: String? = nil
    var big: CGFloat = 30
    var tint: Color = Theme.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(Theme.sans(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
            HStack(alignment: .center, spacing: 8) {
                Text(value).font(Theme.sans(big * 0.86, .semibold)).foregroundStyle(tint).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6).contentTransition(.numericText())
                if let pill { pill }
                if let note { Text(note).font(Theme.sans(11.5)).foregroundStyle(Theme.faint).lineLimit(1) }
            }
        }
    }
}

/// Diagonal stripes: a bar or a day whose numbers are not all in yet.
struct Hatch: View {
    var color: Color = Theme.muted

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(0.08)))
            var p = Path()
            var x = -size.height
            while x < size.width {
                p.move(to: CGPoint(x: x, y: size.height)); p.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 5
            }
            ctx.stroke(p, with: .color(color.opacity(0.32)), lineWidth: 1.6)
        }
    }
}

/// One bar of the kit. Its height comes from the frame it is given.
struct KitBar: View {
    enum Kind { case rest, key, partial, ghost, none }
    var kind: Kind = .rest
    var color: Color = Theme.accent
    var hover = false
    var radius: CGFloat = 4

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius, style: .continuous)
        switch kind {
        case .rest: shape.fill(hover ? Kit.restHover : Kit.rest)
        case .key: shape.fill(Kit.key(color)).opacity(hover ? 1 : 0.95)
        case .partial: Hatch().clipShape(shape)
        case .ghost: shape.strokeBorder(Kit.ghost, style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
        case .none: RoundedRectangle(cornerRadius: radius).strokeBorder(Kit.grid, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        }
    }
}

/// The hairlines and the numbers on the right. The plot is the space left of `Kit.axis`.
struct KitGrid: View {
    let ticks: [Double]
    var label: (Double) -> String = Kit.short
    /// Space above the top line, for notes over the plot.
    var top: CGFloat = 0

    var body: some View {
        GeometryReader { g in
            let lo = ticks.first ?? 0, hi = max(ticks.last ?? 1, lo + 1), w = g.size.width - Kit.axis, h = g.size.height - top
            ZStack(alignment: .topLeading) {
                ForEach(ticks, id: \.self) { t in
                    let y = top + h - h * (t - lo) / (hi - lo)
                    Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y)) }
                        .stroke(Kit.grid, style: StrokeStyle(lineWidth: 1, dash: t == lo ? [] : Kit.dash))
                    Text(label(t)).font(Theme.mono(10)).foregroundStyle(Theme.faint).lineLimit(1)
                        .frame(width: Kit.axis - 6, alignment: .leading)
                        .position(x: w + 6 + (Kit.axis - 6) / 2, y: y)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// The floating card over a chart: a key bar in the series color, the value, the date, then
/// an optional change row under a dashed rule.
struct ChartTip: View {
    let value: String
    let date: String
    var color: Color = Theme.accent
    var lines: [(String, String)] = []
    var change: String? = nil
    var changeTone: DeltaPill.Tone = .flat
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3, height: 13)
                Text(value).font(Theme.sans(12, .semibold)).foregroundStyle(Theme.ink).monospacedDigit()
                Text(date).font(Theme.sans(11.5)).foregroundStyle(Theme.faint)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                HStack(spacing: 10) {
                    Text(l.0).foregroundStyle(Theme.muted)
                    Spacer(minLength: 10)
                    Text(l.1).foregroundStyle(Theme.ink).monospacedDigit()
                }
                .font(Theme.sans(11.5))
            }
            if change != nil || note != nil {
                Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: 400, y: 0)) }
                    .stroke(Kit.grid, style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(height: 1).clipped()
                HStack(spacing: 6) {
                    if let change {
                        Text(change).font(Theme.sans(11.5, .semibold)).monospacedDigit()
                            .foregroundStyle(changeTone == .up ? Theme.live : changeTone == .down ? Theme.danger : Theme.muted)
                    }
                    if let note { Text(note).font(Theme.sans(11.5)).foregroundStyle(Theme.faint) }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(minWidth: 130, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
        .shadow(color: Theme.shadow, radius: 10, y: 4)
        .fixedSize()
        .allowsHitTesting(false)
    }
}

/// "■ This week  ┆ The week before": the key under or over a chart.
struct KitKey: View {
    enum Mark { case solid(Color), dashed, stripes, line(Color) }
    let items: [(Mark, String)]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, i in
                HStack(spacing: 6) {
                    switch i.0 {
                    case .solid(let c): RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 9, height: 9)
                    case .dashed:
                        RoundedRectangle(cornerRadius: 2).strokeBorder(Kit.ghost, style: StrokeStyle(lineWidth: 1.2, dash: [2, 2]))
                            .frame(width: 10, height: 10)
                    case .stripes: Hatch().clipShape(RoundedRectangle(cornerRadius: 2)).frame(width: 10, height: 10)
                    case .line(let c): Capsule().fill(c).frame(width: 12, height: 2)
                    }
                    Text(i.1).font(Theme.sans(11)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
        }
    }
}

/// Where a floating tip goes beside x in a plot `w` wide: right of the point when it fits.
func kitTipX(_ x: CGFloat, width: CGFloat, in w: CGFloat, gap: CGFloat = 14) -> CGFloat {
    x + gap + width <= w ? x + gap + width / 2 : max(width / 2, x - gap - width / 2)
}

/// A small line for a number tile: the accent over a soft fill when it is the point, else gray.
/// The last point gets a dot.
struct KitSpark: View {
    let values: [Int]
    var key = true
    var color: Color = Theme.accent

    var body: some View {
        GeometryReader { g in
            let v = values.map(Double.init)
            let lo = v.min() ?? 0, hi = max(v.max() ?? 1, lo + 1)
            let c = key ? color : Theme.muted.opacity(0.7)
            if v.count > 1 {
                if key { Kit.fill(v, in: g.size, lo: lo, hi: hi).fill(Kit.area(c)) }
                Kit.line(v, in: g.size, lo: lo, hi: hi).stroke(c, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                Circle().fill(c).frame(width: 5, height: 5)
                    .position(x: g.size.width, y: g.size.height - g.size.height * (v.last! - lo) / (hi - lo))
            }
        }
    }
}
