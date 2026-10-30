import SwiftUI

/// The Mac's chart kit (Sources/Takes/ChartKit.swift), for the phone (2026-10-29). Bars are gray;
/// only the bar that matters gets the accent. The period before is a dashed gray line or a dashed
/// outline. A day still running is striped, a day with no reading yet is a dashed outline. Numbers
/// sit on the right on dashed hairlines. No hover on a phone: a tap picks a day or a month (a band,
/// a crosshair and the same tip as the Mac), a second tap lets go. Every color comes from Palette.
enum Kit {
    static var rest: Color { Palette.muted.opacity(0.22) }
    static var restPicked: Color { Palette.muted.opacity(0.38) }
    static var ghost: Color { Palette.faint.opacity(0.75) }
    static var band: Color { Palette.well }
    static var grid: Color { Palette.border }
    static let dash: [CGFloat] = [3, 4]
    static let axis: CGFloat = 32

    static func key(_ c: Color = Palette.accent) -> LinearGradient {
        LinearGradient(colors: [c, c.opacity(0.55)], startPoint: .top, endPoint: .bottom)
    }

    static func area(_ c: Color = Palette.accent) -> LinearGradient {
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
        var out = [floor(lo / step) * step]
        while out.last! < hi { out.append(out.last! + step) }
        return out
    }

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

    static func fill(_ v: [Double], in size: CGSize, lo: Double, hi: Double, slots: Int? = nil) -> Path {
        var p = line(v, in: size, lo: lo, hi: hi, slots: slots)
        guard v.count > 1 else { return p }
        let n = max(slots ?? v.count, v.count)
        p.addLine(to: CGPoint(x: size.width * Double(v.count - 1) / Double(n - 1), y: size.height))
        p.addLine(to: CGPoint(x: 0, y: size.height))
        p.closeSubpath()
        return p
    }

    /// 940 · 1.2k · 38k · 1.5M.
    static func short(_ v: Double) -> String {
        let a = abs(v)
        if a >= 1_000_000 { return trim(v / 1_000_000) + "M" }
        if a >= 1_000 { return trim(v / 1_000) + "k" }
        return a < 10 && v.rounded() != v ? String(format: "%.1f", v) : String(Int(v.rounded()))
    }

    private static func trim(_ v: Double) -> String {
        abs(v) >= 10 || v.rounded() == v ? String(Int(v.rounded())) : String(format: "%.1f", v)
    }

    static func comma(_ v: Int) -> String { v.formatted(.number.locale(Locale(identifier: "en_US"))) }

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

    /// The slot under a tap at x in a plot `w` wide with `n` points across.
    static func slot(_ x: CGFloat, width w: CGFloat, count n: Int, last: Int) -> Int? {
        guard n > 1, w > 0, x >= 0, x <= w + 8 else { return nil }
        return min(max(Int((x / w * Double(n - 1)).rounded()), 0), last)
    }
}

/// "↑ 25%" in a soft pill: green when it went the good way, red when not, gray when flat.
struct DeltaPill: View {
    enum Tone { case up, down, flat }
    let text: String
    var tone: Tone = .flat
    var size: CGFloat = 11.5

    init?(now: Double, before: Double, goodWhenUp: Bool = true, size: CGFloat = 11.5) {
        guard let t = Kit.change(now, before) else { return nil }
        self.init(t, tone: Kit.tone(now, before, goodWhenUp: goodWhenUp), size: size)
    }

    init(_ text: String, tone: Tone = .flat, size: CGFloat = 11.5) {
        self.text = text; self.tone = tone; self.size = size
    }

    var body: some View {
        Text(text).font(.inter(size: size, .semibold)).monospacedDigit()
            .foregroundStyle(tone == .up ? Palette.live : tone == .down ? Palette.danger : Palette.muted)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(tone == .up ? Palette.liveSoft : tone == .down ? Palette.danger.opacity(0.12) : Palette.well))
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
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.accentInk)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.accentSoft))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.nunito(size: 17)).foregroundStyle(Palette.ink).lineLimit(1)
                if let subtitle { Text(subtitle).font(.inter(size: 11.5)).foregroundStyle(Palette.muted).lineLimit(1) }
            }
            Spacer(minLength: 8)
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
    var big: CGFloat = 26
    var tint: Color = Palette.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.inter(size: 11.5)).foregroundStyle(Palette.muted).lineLimit(1)
            HStack(alignment: .center, spacing: 7) {
                Text(value).font(.inter(size: big * 0.86, .semibold)).foregroundStyle(tint).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6).contentTransition(.numericText())
                if let pill { pill }
                if let note { Text(note).font(.inter(size: 11.5)).foregroundStyle(Palette.faint).lineLimit(1) }
            }
        }
    }
}

/// Diagonal stripes: a bar or a day whose numbers are not all in yet.
struct Hatch: View {
    var color: Color = Palette.muted

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
    var color: Color = Palette.accent
    var picked = false
    var radius: CGFloat = 4

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius, style: .continuous)
        switch kind {
        case .rest: shape.fill(picked ? Kit.restPicked : Kit.rest)
        case .key: shape.fill(Kit.key(color))
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
    var top: CGFloat = 0

    var body: some View {
        GeometryReader { g in
            let lo = ticks.first ?? 0, hi = max(ticks.last ?? 1, lo + 1), w = g.size.width - Kit.axis, h = g.size.height - top
            ZStack(alignment: .topLeading) {
                ForEach(ticks, id: \.self) { t in
                    let y = top + h - h * (t - lo) / (hi - lo)
                    Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y)) }
                        .stroke(Kit.grid, style: StrokeStyle(lineWidth: 1, dash: t == lo ? [] : Kit.dash))
                    Text(label(t)).font(.inter(size: 10).monospacedDigit()).foregroundStyle(Palette.faint).lineLimit(1)
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
    var color: Color = Palette.accent
    var lines: [(String, String)] = []
    var change: String? = nil
    var changeTone: DeltaPill.Tone = .flat
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3, height: 13)
                Text(value).font(.inter(size: 12, .semibold)).foregroundStyle(Palette.ink).monospacedDigit()
                Text(date).font(.inter(size: 11.5)).foregroundStyle(Palette.faint)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                HStack(spacing: 10) {
                    Text(l.0).foregroundStyle(Palette.muted)
                    Spacer(minLength: 10)
                    Text(l.1).foregroundStyle(Palette.ink).monospacedDigit()
                }
                .font(.inter(size: 11.5))
            }
            if change != nil || note != nil {
                Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: 400, y: 0)) }
                    .stroke(Kit.grid, style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(height: 1).clipped()
                HStack(spacing: 6) {
                    if let change {
                        Text(change).font(.inter(size: 11.5, .semibold)).monospacedDigit()
                            .foregroundStyle(changeTone == .up ? Palette.live : changeTone == .down ? Palette.danger : Palette.muted)
                    }
                    if let note { Text(note).font(.inter(size: 11.5)).foregroundStyle(Palette.faint) }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(minWidth: 120, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.paper))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.border))
        .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
        .fixedSize()
        .allowsHitTesting(false)
    }
}

/// "■ This week  ┆ The week before": the key under or over a chart.
struct KitKey: View {
    enum Mark { case solid(Color), dashed, stripes, line(Color) }
    let items: [(Mark, String)]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, i in
                HStack(spacing: 5) {
                    switch i.0 {
                    case .solid(let c): RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 9, height: 9)
                    case .dashed:
                        RoundedRectangle(cornerRadius: 2).strokeBorder(Kit.ghost, style: StrokeStyle(lineWidth: 1.2, dash: [2, 2]))
                            .frame(width: 10, height: 10)
                    case .stripes: Hatch().clipShape(RoundedRectangle(cornerRadius: 2)).frame(width: 10, height: 10)
                    case .line(let c): Capsule().fill(c).frame(width: 12, height: 2)
                    }
                    Text(i.1).font(.inter(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                }
            }
        }
    }
}

/// Where a floating tip goes beside x in a plot `w` wide: right of the point when it fits.
func kitTipX(_ x: CGFloat, width: CGFloat, in w: CGFloat, gap: CGFloat = 12) -> CGFloat {
    x + gap + width <= w ? x + gap + width / 2 : max(width / 2, x - gap - width / 2)
}

/// A small line for a number tile: the accent over a soft fill when it is the point, else gray.
struct KitSpark: View {
    let values: [Int]
    var key = true
    var color: Color = Palette.accent

    var body: some View {
        GeometryReader { g in
            let v = values.map(Double.init)
            let lo = v.min() ?? 0, hi = max(v.max() ?? 1, lo + 1)
            let c = key ? color : Palette.muted.opacity(0.7)
            if v.count > 1 {
                if key { Kit.fill(v, in: g.size, lo: lo, hi: hi).fill(Kit.area(c)) }
                Kit.line(v, in: g.size, lo: lo, hi: hi).stroke(c, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                Circle().fill(c).frame(width: 5, height: 5)
                    .position(x: g.size.width, y: g.size.height - g.size.height * (v.last! - lo) / (hi - lo))
            }
        }
    }
}

// MARK: - Charts

/// Daily values as a line over a soft fill, the period before as a dashed gray line, the numbers on
/// the right. A tap: a dashed crosshair, a ring on the line and a tip with the change against the
/// same day of the period before.
struct KitArea: View {
    let dates: [String]
    let values: [Int]
    let color: Color
    var unit = "impressions"
    var height: CGFloat = 150
    /// false: the lowest value sits at the bottom (a follower count), not zero.
    var zeroBase = true
    /// dates.count when values stop early: the line ends where the data ends.
    var slots: Int? = nil
    var prior: [Int]? = nil
    /// Indexes of days with a post: a small tick on the base line.
    var marks: Set<Int> = []
    @State var picked: Int? = nil

    var body: some View {
        let v = values.map(Double.init), was = (prior ?? []).map(Double.init)
        let n = max(slots ?? values.count, values.count)
        let top: CGFloat = 6
        let all = v + was
        let ticks = zeroBase ? Kit.ticks(all.max() ?? 1) : Kit.ticks(lo: all.min() ?? 0, hi: all.max() ?? 1)
        let lo = ticks.first ?? 0, hi = max(ticks.last ?? 1, lo + 1)
        VStack(spacing: 6) {
            GeometryReader { g in
                let w = g.size.width - Kit.axis, h = g.size.height - top
                let size = CGSize(width: w, height: h)
                let x = { (i: Int) in n > 1 ? w * Double(i) / Double(n - 1) : 0 }
                let y = { (val: Double) in top + h - h * (val - lo) / (hi - lo) }
                ZStack(alignment: .topLeading) {
                    KitGrid(ticks: ticks, top: top)
                    Group {
                        if was.count > 1 {
                            Kit.line(was, in: size, lo: lo, hi: hi, slots: n)
                                .stroke(Kit.ghost, style: StrokeStyle(lineWidth: 1.4, lineJoin: .round, dash: [3, 3]))
                        }
                        Kit.fill(v, in: size, lo: lo, hi: hi, slots: n).fill(Kit.area(color))
                        Kit.line(v, in: size, lo: lo, hi: hi, slots: n)
                            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                    .offset(y: top)
                    ForEach(marks.sorted(), id: \.self) { i in
                        if i < n { Capsule().fill(color.opacity(0.6)).frame(width: 2, height: 6).position(x: x(i), y: top + h - 3) }
                    }
                    if let i = picked, i < values.count, values.count > 1 {
                        Path { p in p.move(to: CGPoint(x: x(i), y: top)); p.addLine(to: CGPoint(x: x(i), y: top + h)) }
                            .stroke(color, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        if i < was.count {
                            Circle().fill(Kit.ghost).frame(width: 5, height: 5).position(x: x(i), y: y(was[i]))
                        }
                        Circle().fill(Palette.paper).overlay(Circle().strokeBorder(color, lineWidth: 2))
                            .frame(width: 10, height: 10).position(x: x(i), y: y(v[i]))
                        tip(i).position(x: kitTipX(x(i), width: 160, in: w), y: top + 34)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { p in
                    let i = Kit.slot(p.x, width: w, count: n, last: values.count - 1)
                    withAnimation(Brand.quick) { picked = i == picked ? nil : i }
                }
            }
            axis(n)
        }
        .frame(height: height + 18)
    }

    private func tip(_ i: Int) -> some View {
        let was = prior.flatMap { i < $0.count ? $0[i] : nil }
        let d = was.map { values[i] - $0 }
        return ChartTip(value: "\(Kit.comma(values[i])) \(unit)", date: KitDate.weekdayDay(dates[i]), color: color,
                        change: d.map { $0 == 0 ? "same" : ($0 > 0 ? "+" : "−") + Kit.comma(abs($0)) },
                        changeTone: d.map { $0 > 0 ? .up : $0 < 0 ? .down : .flat } ?? .flat,
                        note: was.map { "vs \(Kit.comma($0)), \(prior!.count) days before" })
    }

    /// Four dates under the plot; the picked day in the accent.
    private func axis(_ n: Int) -> some View {
        GeometryReader { g in
            let w = g.size.width - Kit.axis
            let picks = n > 3 ? [0, n / 3, 2 * n / 3, n - 1] : Array(0..<n)
            ForEach(picks, id: \.self) { i in
                if i < dates.count {
                    Text(KitDate.day(dates[i])).font(.inter(size: 10.5)).foregroundStyle(Palette.faint).fixedSize()
                        .position(x: min(max(n > 1 ? w * Double(i) / Double(n - 1) : 0, 20), w - 20), y: 6)
                        .opacity(picked.map { abs($0 - i) < max(n / 7, 1) } == true ? 0 : 1)
                }
            }
            if let i = picked, i < dates.count {
                Text(KitDate.day(dates[i])).font(.inter(size: 10.5, .semibold)).foregroundStyle(Palette.accentInk).fixedSize()
                    .position(x: min(max(n > 1 ? w * Double(i) / Double(n - 1) : 0, 20), w - 20), y: 6)
            }
        }
        .frame(height: 12)
    }
}

/// Monthly bars on one axis: gray, the best month in the accent, the month still running striped.
/// A tap: a band behind the month and a tip with the change from the month before.
struct KitMonthBars: View {
    /// "yyyy-MM" and the value.
    let points: [(month: String, value: Int)]
    var color: Color = Palette.accent
    var unit = "impressions"
    var height: CGFloat = 140
    @State var picked: Int? = nil

    var body: some View {
        let hi = max(points.map(\.value).max() ?? 1, 1)
        let ticks = Kit.ticks(Double(hi)), top = ticks.last ?? 1
        let running = KitDate.thisMonth()
        VStack(spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                KitGrid(ticks: ticks)
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(Array(points.enumerated()), id: \.offset) { i, p in
                        let kind: KitBar.Kind = p.month.hasPrefix(running) ? .partial : p.value == hi ? .key : .rest
                        ZStack(alignment: .bottom) {
                            if picked == i { RoundedRectangle(cornerRadius: 6).fill(Kit.band) }
                            KitBar(kind: kind, color: color, picked: picked == i)
                                .frame(height: max(2, height * Double(p.value) / top))
                                .padding(.horizontal, 2)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(Brand.quick) { picked = picked == i ? nil : i } }
                    }
                }
                .padding(.trailing, Kit.axis)
                .frame(height: height, alignment: .bottom)
                if let i = picked {
                    GeometryReader { g in
                        let w = g.size.width - Kit.axis, slot = w / Double(max(points.count, 1))
                        tip(i).position(x: kitTipX(slot * (Double(i) + 0.5), width: 150, in: w, gap: slot / 2 + 4), y: 34)
                    }
                    .allowsHitTesting(false)
                }
            }
            .frame(height: height)
            HStack(spacing: 4) {
                ForEach(Array(points.enumerated()), id: \.offset) { i, p in
                    Text(String(KitDate.month(p.month).prefix(points.count > 9 ? 1 : 3)))
                        .font(.inter(size: 10.5, picked == i ? .semibold : .regular))
                        .foregroundStyle(picked == i ? Palette.accentInk : Palette.faint).frame(maxWidth: .infinity)
                }
            }
            .padding(.trailing, Kit.axis)
        }
    }

    private func tip(_ i: Int) -> some View {
        let p = points[i], before = i > 0 ? points[i - 1] : nil
        let running = p.month.hasPrefix(KitDate.thisMonth())
        return ChartTip(value: "\(Kit.comma(p.value)) \(unit)", date: KitDate.month(p.month, year: true), color: color,
                        change: running ? nil : before.flatMap { Kit.change(Double(p.value), Double($0.value)) },
                        changeTone: before.map { Kit.tone(Double(p.value), Double($0.value)) } ?? .flat,
                        note: running ? "month so far" : before.map { "vs \(KitDate.month($0.month))" })
    }
}

/// Two series per month on one scale: LinkedIn in its blue, X in ink. A tap shows both numbers.
struct KitDualBars: View {
    let months: [String]
    let a: [Int], b: [Int]
    let colors: (Color, Color)
    let names: (String, String)
    var height: CGFloat = 130
    @State var picked: Int? = nil

    var body: some View {
        let hi = max(a.max() ?? 1, b.max() ?? 1, 1)
        let ticks = Kit.ticks(Double(hi)), top = ticks.last ?? 1
        VStack(spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                KitGrid(ticks: ticks)
                HStack(alignment: .bottom, spacing: 5) {
                    ForEach(months.indices, id: \.self) { i in
                        ZStack(alignment: .bottom) {
                            if picked == i { RoundedRectangle(cornerRadius: 6).fill(Kit.band) }
                            HStack(alignment: .bottom, spacing: 2) {
                                KitBar(kind: .key, color: colors.0, radius: 3).frame(height: max(2, height * Double(a[i]) / top))
                                KitBar(kind: .key, color: colors.1.opacity(0.7), radius: 3).frame(height: max(2, height * Double(b[i]) / top))
                            }
                            .padding(.horizontal, 2)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(Brand.quick) { picked = picked == i ? nil : i } }
                    }
                }
                .padding(.trailing, Kit.axis)
                if let i = picked {
                    GeometryReader { g in
                        let w = g.size.width - Kit.axis, slot = w / Double(max(months.count, 1))
                        ChartTip(value: KitDate.month(months[i], year: true), date: "", color: Palette.muted,
                                 lines: [(names.0, Kit.comma(a[i])), (names.1, Kit.comma(b[i]))])
                            .position(x: kitTipX(slot * (Double(i) + 0.5), width: 140, in: w, gap: slot / 2 + 4), y: 40)
                    }
                    .allowsHitTesting(false)
                }
            }
            .frame(height: height)
            HStack(spacing: 5) {
                ForEach(months.indices, id: \.self) { i in
                    Text(String(KitDate.month(months[i]).prefix(months.count > 9 ? 1 : 3)))
                        .font(.inter(size: 10.5, picked == i ? .semibold : .regular))
                        .foregroundStyle(picked == i ? Palette.accentInk : Palette.faint).frame(maxWidth: .infinity)
                }
            }
            .padding(.trailing, Kit.axis)
        }
    }
}

/// Date labels for the charts: "Oct 29", "Thu, Oct 29", "Oct", "Oct 2026".
@MainActor
enum KitDate {
    static func day(_ s: String) -> String { PerformanceView.month(s, day: true) }
    static func weekdayDay(_ s: String) -> String {
        guard let d = PerformanceView.day(s) else { return s }
        return Fmt.weekdayPOSIX.string(from: d) + ", " + Fmt.monthDayPOSIX.string(from: d)
    }
    static func month(_ s: String, year: Bool = false) -> String {
        guard let d = Fmt.month.date(from: String(s.prefix(7))) else { return s }
        return (year ? Fmt.monthYear : Fmt.shortMonth).string(from: d)
    }
    static func thisMonth() -> String { Fmt.month.string(from: Date()) }
}
