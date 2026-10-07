import SwiftUI

// The Signal social dashboard, drawn natively (2026-09-29). your notes repo's generate_dashboard.py
// writes <library>/_library/social.json (about 20 KB) with the numbers of every chart; this file
// reads it once and draws each chart with Path and plain views. No web view, no chart library.

struct SocialData: Decodable, Equatable {
    struct Hero: Decodable, Equatable {
        var followers: Int
        var followers_gain_8d: Int
        var followers_spark: [Int]
        var new_followers_spark: [Int]
        var impr_per_day: Int
        var month: String
        var prev_month: String
        var mom_pct: Int
        var impr_spark: [Int]
        var rate: Double
        var engagements: Int
        var total_impressions: Int
        var peak_month: String
        var peak_impressions: Int
    }
    struct Momentum: Decodable, Equatable {
        struct Note: Decodable, Equatable { var date: String; var label: String }
        var dates: [String]
        var linkedin: [Int]
        /// null after the last day the X data covers.
        var x: [Int?]
        var annotations: [Note]
    }
    struct Cadence: Decodable, Equatable {
        var posts: Int; var target: Int; var week: Int; var li_drafts: Int; var x_drafts: Int
    }
    struct Heat: Decodable, Equatable {
        /// null = no data for that day yet (after the source's last day), not zero.
        var dates: [String]; var impressions: [Int?]; var li_posts: [Int]; var x_posts: [Int?]
    }
    struct Entry: Decodable, Equatable, Identifiable {
        var title: String; var url: String; var date: String; var reach: Int; var engagements: Int; var rate: Double
        /// Only on posts ScrapeCreators read (the recent LinkedIn ones).
        var comments: Int? = nil; var reposts: Int? = nil
        var id: String { url + date + title }
    }
    struct Board: Decodable, Equatable { var label: String; var avg: Int; var count: Int }
    struct Window: Decodable, Equatable {
        var posts: Int; var impressions: Int; var avg: Int; var analyzed: Int
        var top: [Entry]
        var by_day: [Board]; var by_hook: [Board]; var by_length: [Board]; var by_topic: [Board]
    }
    struct Point: Decodable, Equatable { var month: String; var value: Int }
    struct Day: Decodable, Equatable { var date: String; var value: Int }
    struct Cross: Decodable, Equatable { var months: [String]; var linkedin: [Int]; var x: [Int] }
    struct Share: Decodable, Equatable { var label: String; var pct: Double }
    struct Group: Decodable, Equatable { var title: String; var items: [Share] }
    struct XTotals: Decodable, Equatable { var posts: Int; var views: Int }
    /// Last day each source covers (YYYY-MM-DD), and when the refresh last loaded anything.
    struct Sources: Decodable, Equatable {
        var linkedin: String; var followers: String; var x: String; var refreshed: String
    }

    var generated: String
    var exported: String
    var sources: Sources?
    var x_through: String
    var hero: Hero
    var momentum: Momentum
    var cadence: Cadence
    var heat: Heat
    var patterns: [String: Window]
    var recent: [Entry]
    var monthly_linkedin: [Point]
    var monthly_x: [Point]
    var cross: Cross
    var followers: [Day]
    var audience: [Group]
    var top_linkedin: [Entry]
    var top_x: [Entry]
    var x_totals: XTotals

    static func file(_ root: URL) -> URL { root.appending(path: "_library/social.json") }

    static func read(_ root: URL) -> SocialData? {
        guard let data = try? Data(contentsOf: file(root)) else { return nil }
        return try? JSONDecoder().decode(SocialData.self, from: data)
    }
}

enum Signal {
    static let linkedin = LinkedIn.blue
    static let x = Theme.ink
    static let peak = Theme.accent

    // One formatter each, made once: the board formats a few hundred dates per draw, and a new
    // DateFormatter each time showed up as scroll lag (2026-10-03).
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter(); f.dateFormat = format; return f
    }
    static let ymd = formatter("yyyy-MM-dd")
    private static let ym = formatter("yyyy-MM")
    private static let monthName = formatter("MMM"), monthYear = formatter("MMM yyyy")
    private static let monthDay = formatter("MMM d"), weekdayName = formatter("EEE")
    private static let refreshedFormat = formatter("yyyy-MM-dd HH:mm")

    /// "2026-09" → "Sep". "2026-09-14" → "Sep 14".
    static func month(_ m: String, year: Bool = false) -> String {
        guard let d = ym.date(from: String(m.prefix(7))) else { return m }
        return (year ? monthYear : monthName).string(from: d)
    }

    static func day(_ s: String) -> String {
        guard let d = ymd.date(from: String(s.prefix(10))) else { return s }
        return monthDay.string(from: d)
    }

    static func weekday(_ s: String) -> String {
        guard let d = ymd.date(from: String(s.prefix(10))) else { return "" }
        return weekdayName.string(from: d).uppercased()
    }

    /// When the numbers were last refreshed: sources.refreshed ("2026-10-02 18:01"), else when the
    /// dashboard file was written.
    static func updated(_ data: SocialData) -> Date? {
        if let r = data.sources?.refreshed, let d = refreshedFormat.date(from: r) { return d }
        return ISO8601DateFormatter().date(from: data.generated)
    }

    static func comma(_ n: Int) -> String { n.formatted(.number) }

    /// Whole days from "2026-09-27" to today. nil when the date does not parse.
    static func daysOld(_ s: String, now: Date = .now) -> Int? {
        guard let d = ymd.date(from: String(s.prefix(10))) else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day
    }
}

// MARK: - Section frame

/// "LABEL" + a title, then the content. The look of the website's section headers.
struct SignalSection<Content: View, Trailing: View>: View {
    let label: String
    let title: String
    var platform: String? = nil
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if let platform { PlatformLogo(platform: platform, size: 12) }
                        SectionLabel(text: label)
                    }
                    Text(title).font(Theme.sans(15, .semibold)).foregroundStyle(Theme.ink)
                }
                Spacer(minLength: 8)
                trailing
            }
            content
        }
        .padding(.top, 8)
    }
}

extension SignalSection {
    init(label: String, title: String, platform: String? = nil,
         @ViewBuilder content: () -> Content, @ViewBuilder trailing: () -> Trailing) {
        self.label = label; self.title = title; self.platform = platform
        self.trailing = trailing(); self.content = content()
    }
}

extension SignalSection where Trailing == EmptyView {
    init(label: String, title: String, platform: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label; self.title = title; self.platform = platform
        self.trailing = EmptyView(); self.content = content()
    }
}

// MARK: - Hero

struct SignalHero: View {
    let hero: SocialData.Hero

    var body: some View {
        HStack(spacing: 12) {
            metric("followers", Signal.comma(hero.followers), "+\(hero.followers_gain_8d) in the last 8 days",
                   up: true, spark: hero.followers_spark, color: Theme.secondary)
            metric("impressions / day · \(hero.month)", Signal.comma(hero.impr_per_day),
                   "\(hero.mom_pct >= 0 ? "↑" : "↓") \(abs(hero.mom_pct))% vs \(hero.prev_month)",
                   up: hero.mom_pct >= 0, spark: hero.impr_spark, color: Theme.accent)
            metric("engagement rate · \(hero.month)", String(format: "%.1f%%", hero.rate),
                   "\(hero.engagements) engagements", up: nil, spark: hero.new_followers_spark, color: Theme.muted)
            metric("impressions · 12 months", Num.short(hero.total_impressions),
                   "Peak: \(hero.peak_month) · \(Num.short(hero.peak_impressions))", up: nil, spark: [], color: .clear)
        }
    }

    private func metric(_ label: String, _ value: String, _ note: String, up: Bool?, spark: [Int], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) { PlatformLogo(platform: "LinkedIn", size: 11); SectionLabel(text: label) }
            Text(value).font(Theme.display(32)).foregroundStyle(Theme.ink)
            Text(note).font(Theme.sans(11.5))
                .foregroundStyle(up == true ? Color.green.opacity(0.75) : up == false ? Theme.accentInk : Theme.muted)
                .lineLimit(1)
            LineShape(values: spark.map(Double.init)).stroke(color, lineWidth: 1.5).frame(height: 26)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
    }
}

/// The top tiles when the board shows only X.
struct XHero: View {
    let data: SocialData

    var body: some View {
        let m = data.momentum
        let views = m.x.compactMap { $0 }
        let last30 = views.suffix(30).reduce(0, +)
        let peak = views.max() ?? 0
        let peakDay = views.firstIndex(of: peak).map { Signal.day(m.dates[$0]) } ?? ""
        let recent = data.monthly_x.last
        HStack(spacing: 12) {
            metric("views · 30 days", Num.short(last30), "through \(Signal.day(data.x_through))", spark: Array(views.suffix(30)))
            metric("best day · \(m.dates.count) days", Signal.comma(peak), peakDay, spark: [])
            metric("views · \(recent.map { Signal.month($0.month) } ?? "this month")", Num.short(recent?.value ?? 0),
                   "month to date", spark: data.monthly_x.map(\.value))
            metric("all time", Num.short(data.x_totals.views), "\(Signal.comma(data.x_totals.posts)) posts", spark: [])
        }
    }

    private func metric(_ label: String, _ value: String, _ note: String, spark: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) { PlatformLogo(platform: "X", size: 11); SectionLabel(text: label) }
            Text(value).font(Theme.display(32)).foregroundStyle(Theme.ink)
            Text(note).font(Theme.sans(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
            LineShape(values: spark.map(Double.init)).stroke(Signal.x, lineWidth: 1.5).frame(height: 26)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
    }
}

// MARK: - Charts

/// A line through values, scaled to the frame. Min at the bottom, max at the top.
struct LineShape: Shape {
    let values: [Double]
    var floorZero = false
    /// Days on the x axis; more than values.count when the data stops before the last day.
    var slots: Int? = nil

    func path(in r: CGRect) -> Path {
        var p = Path()
        let n = max(slots ?? values.count, values.count)
        guard values.count > 1 else { return p }
        let lo = floorZero ? 0 : values.min()!, hi = max(values.max()!, lo + 1)
        for (i, v) in values.enumerated() {
            let pt = CGPoint(x: r.minX + r.width * Double(i) / Double(n - 1),
                             y: r.maxY - r.height * (v - lo) / (hi - lo))
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        return p
    }
}

/// The same line, closed to the bottom for a fill.
struct AreaShape: Shape {
    let values: [Double]
    var floorZero = true
    var slots: Int? = nil
    func path(in r: CGRect) -> Path {
        var p = LineShape(values: values, floorZero: floorZero, slots: slots).path(in: r)
        guard values.count > 1 else { return p }
        let n = max(slots ?? values.count, values.count)
        p.addLine(to: CGPoint(x: r.minX + r.width * Double(values.count - 1) / Double(n - 1), y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// Daily values as a filled area, with a hover readout.
struct AreaChart: View {
    let dates: [String]
    let values: [Int]
    let color: Color
    var unit = "impressions"
    var notes: [SocialData.Momentum.Note] = []
    var height: CGFloat = 150
    /// false: the lowest value sits at the bottom (a follower count), not zero.
    var zeroBase = true
    /// dates.count when values stop early: the line ends where the data ends.
    var slots: Int? = nil
    @State private var hover: Int?

    var body: some View {
        let v = values.map(Double.init)
        let span = Double(max(slots ?? values.count, values.count) - 1)
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let lo = zeroBase ? 0 : (v.min() ?? 0)
            let hi = max(v.max() ?? 1, lo + 1)
            // A band above the highest point holds the labels, so a label never sits on the line.
            let top: CGFloat = notes.isEmpty ? 0 : 22
            let y = { (x: Double) in h - (h - top) * (x - lo) / (hi - lo) }
            ZStack(alignment: .topLeading) {
                ForEach([0.25, 0.5, 0.75], id: \.self) { f in
                    Rectangle().fill(Theme.border.opacity(0.6)).frame(height: 1).offset(y: h * f)
                }
                AreaShape(values: v, floorZero: zeroBase, slots: slots).fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0.02)],
                                                         startPoint: .top, endPoint: .bottom))
                    .padding(.top, top)
                LineShape(values: v, floorZero: zeroBase, slots: slots).stroke(color, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                    .padding(.top, top)
                ForEach(notes, id: \.date) { n in
                    if let i = dates.firstIndex(of: n.date), i < values.count, values.count > 1 {
                        let x = w * Double(i) / span
                        Circle().stroke(Theme.accent, lineWidth: 1.5).frame(width: 8, height: 8).position(x: x, y: y(v[i]))
                        Text(n.label).font(Theme.mono(10)).foregroundStyle(Theme.accentInk)
                            .fixedSize().position(x: min(max(x, 90), w - 90), y: max(y(v[i]) - 14, 7))
                    }
                }
                if let i = hover, i < values.count, values.count > 1 {
                    let x = w * Double(i) / span
                    Rectangle().fill(Theme.muted.opacity(0.5)).frame(width: 1, height: h).position(x: x, y: h / 2)
                    Circle().fill(color).frame(width: 7, height: 7).position(x: x, y: y(v[i]))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Signal.day(dates[i]).uppercased()).font(Theme.mono(9.5)).foregroundStyle(Theme.muted)
                        Text("\(Signal.comma(values[i])) \(unit)").font(Theme.mono(12, .medium)).foregroundStyle(Theme.ink)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.radius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
                    .fixedSize()
                    .position(x: min(max(x, 70), w - 70), y: 18)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let p) = phase, values.count > 1 {
                    hover = min(max(Int((p.x / w * span).rounded()), 0), values.count - 1)
                } else { hover = nil }
            }
        }
        .frame(height: height)
    }
}

/// Monthly bars; the best month in the accent color. Hover shows the value.
struct MonthBars: View {
    let points: [SocialData.Point]
    let color: Color
    var unit = "impressions"
    var height: CGFloat = 140
    @State private var hover: Int?

    var body: some View {
        let hi = max(points.map(\.value).max() ?? 1, 1)
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(points.enumerated()), id: \.offset) { i, p in
                    VStack(spacing: 3) {
                        Text(Num.short(p.value)).font(Theme.mono(9.5))
                            .foregroundStyle(hover == i || p.value == hi ? Theme.ink : Theme.muted)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(p.value == hi ? Signal.peak : color.opacity(hover == i ? 0.9 : 0.55))
                            .frame(height: max(2, (height - 18) * Double(p.value) / Double(hi)))
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onHover { hover = $0 ? i : (hover == i ? nil : hover) }
                }
            }
            .frame(height: height, alignment: .bottom)
            HStack(spacing: 6) {
                ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                    Text(Signal.month(p.month)).font(Theme.mono(9.5)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
                }
            }
        }
    }
}

/// Two bars per month, each scaled to its own platform, so the shapes compare.
struct DualBars: View {
    let cross: SocialData.Cross
    var height: CGFloat = 120

    var body: some View {
        let li = max(cross.linkedin.max() ?? 1, 1), x = max(cross.x.max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                legend(Signal.linkedin, "LinkedIn impressions (peak \(Num.short(li)))")
                legend(Signal.x, "X views (peak \(Num.short(x)))")
            }
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(cross.months.indices, id: \.self) { i in
                    VStack(spacing: 4) {
                        HStack(alignment: .bottom, spacing: 2) {
                            bar(cross.linkedin[i], li, Signal.linkedin)
                            bar(cross.x[i], x, Signal.x.opacity(0.75))
                        }
                        .frame(height: height, alignment: .bottom)
                        Text(Signal.month(cross.months[i])).font(Theme.mono(9.5)).foregroundStyle(Theme.muted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func bar(_ v: Int, _ hi: Int, _ c: Color) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(c).frame(height: max(2, height * Double(v) / Double(hi)))
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 5) { RoundedRectangle(cornerRadius: 1).fill(c).frame(width: 10, height: 10); Text(t) }
            .font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
    }
}

/// 13 weeks × 7 days, Monday on top. Darker is more.
struct HeatGrid: View {
    let dates: [String]
    /// nil: no data for that day yet. Drawn as an outline, never as a quiet day.
    let values: [Int?]
    let color: Color
    let unit: String
    /// The cell under the pointer. One readout for the grid: a tooltip on each of the 91 cells
    /// made every scroll past the grid slow (2026-10-03).
    @State private var hover: Int?

    var body: some View {
        let hi = max(values.compactMap { $0 }.max() ?? 1, 1)
        // Pad the front so the first column starts on a Monday.
        let lead = weekdayIndex(dates.first ?? "")
        let cells: [Int??] = Array(repeating: nil, count: lead) + values.map { Optional($0) }
        let weeks = Int((Double(cells.count) / 7).rounded(.up))
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .trailing, spacing: 3) {
                ForEach(0..<7, id: \.self) { r in
                    Text(["Mon", "", "Wed", "", "Fri", "", "Sun"][r]).font(Theme.mono(9)).foregroundStyle(Theme.muted)
                        .frame(height: 14)
                }
            }
            // One drawing, not 91 views: each cell as its own view made the board a thousand
            // layers for Core Animation to move on every scroll frame (2026-10-03).
            Canvas { ctx, _ in
                for i in cells.indices {
                    let r = CGRect(x: Double(i / 7) * 17, y: Double(i % 7) * 17, width: 14, height: 14)
                    guard let cell = cells[i] else { continue }
                    let shape = Path(roundedRect: r, cornerRadius: 2)
                    if let v = cell {
                        ctx.fill(shape, with: .color(v == 0 ? Theme.border.opacity(0.5) : color.opacity(0.18 + 0.82 * Double(v) / Double(hi))))
                    } else {
                        ctx.stroke(Path(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 2), with: .color(Theme.border),
                                   style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    }
                }
            }
            .frame(width: Double(weeks) * 17 - 3, height: 7 * 17 - 3)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard case .active(let p) = phase else { hover = nil; return }
                let i = Int(p.x / 17) * 7 + Int(p.y / 17) - lead
                hover = i >= 0 && i < dates.count ? i : nil
            }
            .overlay(alignment: .bottomLeading) {
                if let i = hover {
                    Text(values[i].map { "\(Signal.day(dates[i])): \(Signal.comma($0)) \(unit)" } ?? "\(Signal.day(dates[i])): no data yet")
                        .font(Theme.mono(10.5)).foregroundStyle(Theme.ink)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.radius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
                        .fixedSize()
                        .offset(y: 26)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func weekdayIndex(_ s: String) -> Int {
        guard let d = Signal.ymd.date(from: s) else { return 0 }
        return (Calendar(identifier: .gregorian).component(.weekday, from: d) + 5) % 7  // Mon = 0
    }
}

/// Label, a bar and a number, for leaderboards and the audience.
struct BarRow: View {
    let label: String
    let fraction: Double
    let value: String
    var detail: String? = nil
    var strong = false

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(Theme.sans(12, strong ? .semibold : .regular)).foregroundStyle(Theme.ink)
                .lineLimit(1).frame(width: 118, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.border.opacity(0.5))
                    RoundedRectangle(cornerRadius: 2).fill(strong ? Theme.accent : Theme.muted.opacity(0.55))
                        .frame(width: max(2, g.size.width * fraction))
                }
            }
            .frame(height: 6)
            Text(value).font(Theme.mono(11)).foregroundStyle(Theme.ink).frame(width: 48, alignment: .trailing)
            if let detail { Text(detail).font(Theme.mono(10)).foregroundStyle(Theme.muted).frame(width: 24, alignment: .trailing) }
        }
    }
}

/// One line of a "what's working" board: the label and its post count, then a bar with the
/// average impressions. The best one in the accent color.
struct BoardRow: View {
    let item: SocialData.Board
    let fraction: Double
    var best = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.label).font(Theme.sans(12.5, best ? .semibold : .regular)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(item.count == 1 ? "1 post" : "\(item.count) posts").font(Theme.mono(10)).foregroundStyle(Theme.muted)
                Spacer(minLength: 6)
                Text(Signal.comma(item.avg)).font(Theme.mono(11.5, best ? .semibold : .regular)).foregroundStyle(Theme.ink)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.border.opacity(0.5))
                    Capsule().fill(best ? Theme.accent : Theme.muted.opacity(0.5))
                        .frame(width: max(4, g.size.width * fraction))
                }
            }
            .frame(height: 5)
        }
    }
}

/// Average impressions per weekday, Monday to Sunday, as small columns. The best day in the
/// accent color; a day with no post stays an empty slot.
struct DayBars: View {
    let items: [SocialData.Board]
    private static let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        let byDay = Dictionary(items.map { ($0.label, $0) }, uniquingKeysWith: { a, _ in a })
        let hi = max(items.map(\.avg).max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(Self.days, id: \.self) { d in
                let b = byDay[d]
                let best = b?.avg == hi
                VStack(spacing: 4) {
                    Text(b.map { Num.short($0.avg) } ?? "–").font(Theme.mono(10, best ? .semibold : .regular))
                        .foregroundStyle(best ? Theme.ink : Theme.muted)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(b == nil ? Theme.border.opacity(0.5) : best ? Theme.accent : Theme.muted.opacity(0.45))
                        .frame(height: b.map { max(4, 84 * Double($0.avg) / Double(hi)) } ?? 2)
                    Text(d).font(Theme.sans(11.5, best ? .semibold : .regular)).foregroundStyle(Theme.ink)
                    Text(b.map { $0.count == 1 ? "1 post" : "\($0.count) posts" } ?? " ").font(Theme.mono(9.5)).foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 140, alignment: .bottom)
    }
}

// MARK: - Post lists

/// One post: date, title, a reach bar, numbers. Click opens it.
struct SignalPostRow: View {
    let post: SocialData.Entry
    let maxReach: Int
    var rank: Int? = nil
    var unit = "impr"
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            if let rank {
                Text(String(format: "#%02d", rank)).font(Theme.mono(11, .medium)).foregroundStyle(Theme.accentInk).frame(width: 30, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Signal.weekday(post.date)).font(Theme.mono(9)).foregroundStyle(Theme.muted)
                    Text(Signal.day(post.date).uppercased()).font(Theme.mono(11, .medium)).foregroundStyle(Theme.ink)
                }
                .frame(width: 52, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(post.title).font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                if rank != nil {
                    Text(Signal.day(post.date)).font(Theme.mono(10)).foregroundStyle(Theme.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            GeometryReader { g in
                RoundedRectangle(cornerRadius: 2).fill(Theme.accent.opacity(0.7))
                    .frame(width: max(2, g.size.width * Double(post.reach) / Double(max(maxReach, 1))), height: 5)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 90)
            Text(Signal.comma(post.reach)).font(Theme.mono(12, .semibold)).frame(width: 62, alignment: .trailing)
            Text("\(post.engagements)").font(Theme.mono(12)).foregroundStyle(Theme.muted).frame(width: 40, alignment: .trailing)
            Text(String(format: "%.1f%%", post.rate)).font(Theme.mono(12)).foregroundStyle(Theme.muted).frame(width: 48, alignment: .trailing)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(hover ? Theme.surface : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { if let u = URL(string: post.url), !post.url.isEmpty { NSWorkspace.shared.openSoon(u) } }
    }
}

// MARK: - The page

/// Every section of the Signal dashboard, in its order. A plain VStack: as a LazyVStack it froze
/// Takes for seconds on 2026-10-02 (the sample showed SwiftUI measuring its rows again and
/// again, with lazy grids inside). The page has about ten sections, cheap to draw at once.
/// No `.help` tooltips on its bars and rows: AppKit moves each tooltip area on every scroll
/// frame, and 70 of them made scrolling lag (2026-10-03). Hover readouts show the numbers.
struct SignalPage<Extra: View>: View {
    let data: SocialData
    /// Shown after the weekly cadence: the posts from Takes sessions.
    /// "LinkedIn" or "X" shows only that platform's sections. Empty shows all.
    var platform = ""
    @ViewBuilder var extra: Extra
    @AppStorage("signalWindow") private var window = "30"

    private func on(_ p: String) -> Bool { platform.isEmpty || platform == p }

    var body: some View {
        let _ = Perf.body("SignalPage")
        VStack(alignment: .leading, spacing: 26) {
            if on("LinkedIn") { SignalHero(hero: data.hero) } else { XHero(data: data) }
            if on("LinkedIn") { WeekCard(data: data, showX: on("X")) }
            momentum
            extra
            if on("LinkedIn") {
                heat
                patterns
                recent
                SignalSection(label: "12-month journey", title: "Monthly impressions", platform: "LinkedIn") {
                    MonthBars(points: data.monthly_linkedin, color: Signal.linkedin)
                }
                followers
                audience
            }
            if platform.isEmpty, !data.cross.months.isEmpty {
                SignalSection(label: "both platforms", title: "LinkedIn and X on one timeline: same shape, different scale") {
                    DualBars(cross: data.cross)
                }
            }
            if on("X") {
                if !data.monthly_x.isEmpty {
                    SignalSection(label: "12-month journey", title: "Monthly views · \(Signal.comma(data.x_totals.posts)) posts, \(Num.short(data.x_totals.views)) views all time", platform: "X") {
                        MonthBars(points: data.monthly_x, color: Signal.x, unit: "views")
                    }
                }
                SignalSection(label: "posting calendar", title: "13 weeks of X posts", platform: "X") {
                    HeatGrid(dates: data.heat.dates, values: data.heat.x_posts, color: Signal.x, unit: "posts")
                }
                top("All-time top posts", "Five biggest hits by views", "X", data.top_x, unit: "views")
            }
            if on("LinkedIn") {
                top("All-time top posts", "Five biggest hits by impressions", "LinkedIn", data.top_linkedin, unit: "impr")
            }
        }
    }

    private var momentum: some View {
        let m = data.momentum
        return SignalSection(label: "\(m.dates.count)-day momentum", title: platform.isEmpty ? "Daily reach, one row per platform" : "Daily reach", platform: platform.isEmpty ? nil : platform) {
            VStack(alignment: .leading, spacing: 14) {
                if on("LinkedIn") {
                    chartRow("LinkedIn", "impressions", m.linkedin, Signal.linkedin, notes: m.annotations)
                }
                if on("X"), m.x.contains(where: { ($0 ?? 0) > 0 }) {
                    // The line stops on the last day the X data covers.
                    chartRow("X", "views", Array(m.x.prefix { $0 != nil }.compactMap { $0 }), Signal.x, notes: [])
                }
            }
        } trailing: {
            Text("\(Signal.day(m.dates.first ?? "")) – \(Signal.day(m.dates.last ?? ""))".uppercased())
                .font(Theme.mono(10)).foregroundStyle(Theme.muted)
        }
    }

    private func chartRow(_ platform: String, _ unit: String, _ v: [Int], _ c: Color, notes: [SocialData.Momentum.Note]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                PlatformLogo(platform: platform, size: 13)
                Text("\(Num.short(v.reduce(0, +))) \(unit)").font(Theme.mono(11, .medium))
                let peak = v.max() ?? 0
                if let i = v.firstIndex(of: peak), peak > 0 {
                    Text("· peak \(Signal.comma(peak)) on \(Signal.day(data.momentum.dates[i]))").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                }
            }
            AreaChart(dates: data.momentum.dates, values: v, color: c, unit: unit, notes: notes, height: 120,
                      slots: data.momentum.dates.count)
        }
    }

    private func stat(_ n: String, _ label: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(n).font(Theme.display(22))
            Text(label.uppercased()).font(Theme.mono(9.5)).foregroundStyle(Theme.muted)
        }
    }

    private var heat: some View {
        let h = data.heat
        let active = h.impressions.filter { ($0 ?? 0) > 0 }.count
        let posts = h.li_posts.reduce(0, +)
        return HStack(alignment: .top, spacing: 40) {
            SignalSection(label: "impressions activity", title: "\(active) active days in 13 weeks", platform: "LinkedIn") {
                HeatGrid(dates: h.dates, values: h.impressions, color: Theme.secondary, unit: "impressions")
            }
            SignalSection(label: "posting activity", title: "\(posts) posts on \(h.li_posts.filter { $0 > 0 }.count) days", platform: "LinkedIn") {
                HeatGrid(dates: h.dates, values: h.li_posts.map { Optional($0) }, color: Theme.accent, unit: "posts")
            }
        }
    }

    /// Numbers on top, then the posts that worked beside the best day, then three short boards.
    /// Fixed rows, so the cards line up and keep the same height in a row (2026-10-03).
    private var patterns: some View {
        SignalSection(label: "what's working", title: "Patterns from recent posts: what to do more of", platform: "LinkedIn") {
            if let w = data.patterns[window] {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 26) {
                        stat("\(w.posts)", "posts"); stat(Num.short(w.impressions), "total impr")
                        stat(Signal.comma(w.avg), "avg / post"); stat("\(w.analyzed)", "with a draft")
                        Spacer()
                    }
                    HStack(alignment: .top, spacing: 14) {
                        card("Top performers") { performers(w.top) }
                            .layoutPriority(1)
                        card("Best day to post") { DayBars(items: w.by_day) }
                            .frame(width: 380)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top, spacing: 14) {
                        board("Hook type", w.by_hook)
                        board("Length", w.by_length)
                        board("Topic", w.by_topic)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Text("Only posts with a matching draft count for hook, length and topic. Small samples: directional, not statistical.")
                        .font(Theme.sans(11)).foregroundStyle(Theme.muted)
                }
            } else { none }
        } trailing: {
            HStack(spacing: 4) {
                ForEach(["30", "60", "90"], id: \.self) { d in
                    Button("\(d) days") { window = d }.buttonStyle(BracketButtonStyle(active: window == d))
                }
            }
        }
    }

    @ViewBuilder private func performers(_ top: [SocialData.Entry]) -> some View {
        if top.isEmpty { none } else {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("date").frame(width: 50, alignment: .leading)
                    Text("post").frame(maxWidth: .infinity, alignment: .leading)
                    Text("impr").frame(width: 56, alignment: .trailing)
                    Text("er").frame(width: 44, alignment: .trailing)
                }
                .font(Theme.mono(9.5, .medium)).foregroundStyle(Theme.muted).textCase(.uppercase)
                .padding(.bottom, 4)
                ForEach(Array(top.enumerated()), id: \.offset) { i, t in
                    if i > 0 { Rule() }
                    HStack(spacing: 10) {
                        Text(Signal.day(t.date).uppercased()).font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
                            .frame(width: 50, alignment: .leading)
                        Text(t.title).font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(Signal.comma(t.reach)).font(Theme.mono(12, .semibold)).frame(width: 56, alignment: .trailing)
                        Text(String(format: "%.1f%%", t.rate)).font(Theme.mono(11.5)).foregroundStyle(Theme.muted)
                            .frame(width: 44, alignment: .trailing)
                    }
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                    .onTapGesture { if let u = URL(string: t.url), !t.url.isEmpty { NSWorkspace.shared.openSoon(u) } }
                }
            }
        }
    }

    private func board(_ title: String, _ items: [SocialData.Board]) -> some View {
        card(title) {
            if items.isEmpty { none } else {
                let hi = Double(max(items.map(\.avg).max() ?? 1, 1))
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, b in
                        BoardRow(item: b, fraction: Double(b.avg) / hi, best: i == 0)
                    }
                }
            }
        }
    }

    private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.sans(12.5, .semibold))
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(padding: 14)
    }

    private var none: some View { Text("Not enough data").font(Theme.sans(12)).foregroundStyle(Theme.muted) }

    private var recent: some View {
        SignalSection(label: "recent posts", title: "Last \(data.recent.count) published posts", platform: "LinkedIn") {
            postList(data.recent, ranked: false)
        } trailing: {
            Text("CLICK A ROW TO OPEN IT").font(Theme.mono(10)).foregroundStyle(Theme.muted)
        }
    }

    private func top(_ label: String, _ title: String, _ platform: String, _ posts: [SocialData.Entry], unit: String) -> some View {
        SignalSection(label: label, title: title, platform: platform) {
            postList(posts, ranked: true, unit: unit)
        }
    }

    private func postList(_ posts: [SocialData.Entry], ranked: Bool, unit: String = "impr") -> some View {
        let hi = posts.map(\.reach).max() ?? 1
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(ranked ? "rank" : "date").frame(width: ranked ? 30 : 52, alignment: .leading)
                Text("post").frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: 90, height: 1)
                Text(unit).frame(width: 62, alignment: .trailing)
                Text("eng").frame(width: 40, alignment: .trailing)
                Text("er").frame(width: 48, alignment: .trailing)
            }
            .font(Theme.mono(9.5, .medium)).foregroundStyle(Theme.muted).textCase(.uppercase)
            .padding(.horizontal, 8).padding(.bottom, 4)
            Rule()
            ForEach(Array(posts.enumerated()), id: \.offset) { i, p in
                SignalPostRow(post: p, maxReach: hi, rank: ranked ? i + 1 : nil, unit: unit)
                Rule()
            }
        }
    }

    private var followers: some View {
        let f = data.followers
        let first = f.first?.value ?? 0, last = f.last?.value ?? 0
        return SignalSection(label: "follower trajectory", title: "\(f.count)-day follower growth", platform: "LinkedIn") {
            AreaChart(dates: f.map(\.date), values: f.map(\.value), color: Theme.secondary,
                      unit: "followers", height: 120, zeroBase: false)
        } trailing: {
            Text("\(Signal.comma(first)) → \(Signal.comma(last)) · +\(last - first)").font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
        }
    }

    private var audience: some View {
        SignalSection(label: "audience", title: "Who shows up for the content", platform: "LinkedIn") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 24, alignment: .top)], alignment: .leading, spacing: 18) {
                ForEach(data.audience, id: \.title) { g in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(g.title).font(Theme.sans(12.5, .semibold))
                        let hi = g.items.map(\.pct).max() ?? 1
                        ForEach(g.items, id: \.label) { s in
                            BarRow(label: s.label, fraction: s.pct / max(hi, 0.1), value: String(format: "%.1f%%", s.pct))
                        }
                    }
                }
            }
        } trailing: {
            Text("LINKEDIN EXPORT \(data.exported)").font(Theme.mono(10)).foregroundStyle(Theme.muted)
        }
    }
}
