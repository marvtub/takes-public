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
            metric("followers", Signal.comma(hero.followers),
                   DeltaPill("+\(Signal.comma(hero.followers_gain_8d))", tone: hero.followers_gain_8d > 0 ? .up : .flat), "in 8 days",
                   spark: hero.followers_spark, key: false)
            metric("impressions / day · \(hero.month)", Signal.comma(hero.impr_per_day),
                   DeltaPill("\(hero.mom_pct >= 0 ? "↑" : "↓") \(abs(hero.mom_pct))%", tone: hero.mom_pct > 0 ? .up : hero.mom_pct < 0 ? .down : .flat),
                   "vs \(hero.prev_month)", spark: hero.impr_spark, key: true)
            metric("engagement rate · \(hero.month)", String(format: "%.1f%%", hero.rate), nil,
                   "\(Signal.comma(hero.engagements)) engagements", spark: hero.new_followers_spark, key: false)
            metric("impressions · 12 months", Num.short(hero.total_impressions), nil,
                   "Peak: \(hero.peak_month) · \(Num.short(hero.peak_impressions))", spark: [], key: false)
        }
    }

    private func metric(_ label: String, _ value: String, _ pill: DeltaPill?, _ note: String, spark: [Int], key: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) { PlatformLogo(platform: "LinkedIn", size: 11); SectionLabel(text: label) }
            Text(value).font(Theme.display(32)).foregroundStyle(Theme.ink).monospacedDigit()
            HStack(spacing: 6) {
                if let pill { pill }
                Text(note).font(Theme.sans(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            KitSpark(values: spark, key: key).frame(height: 26)
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
            KitSpark(values: spark, key: false).frame(height: 26)
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

/// Daily values as a line over a soft fill, the period before as a dashed gray line, the numbers
/// on the right (ChartKit.swift). Hover: a dashed crosshair, a ring on the line and a tip with
/// the change against the same day of the period before.
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
    /// The same number of days just before, drawn dashed under the line.
    var prior: [Int]? = nil
    /// Indexes of days with a post: a small tick on the base line.
    var marks: Set<Int> = []
    @State private var hover: Int?

    init(dates: [String], values: [Int], color: Color, unit: String = "impressions", notes: [SocialData.Momentum.Note] = [],
         height: CGFloat = 150, zeroBase: Bool = true, slots: Int? = nil, prior: [Int]? = nil, marks: Set<Int> = [], hover: Int? = nil) {
        self.dates = dates; self.values = values; self.color = color; self.unit = unit; self.notes = notes
        self.height = height; self.zeroBase = zeroBase; self.slots = slots; self.prior = prior; self.marks = marks
        _hover = State(initialValue: hover)
    }

    var body: some View {
        let v = values.map(Double.init), was = (prior ?? []).map(Double.init)
        let n = max(slots ?? values.count, values.count)
        let top: CGFloat = notes.isEmpty ? 6 : 24
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
                    ForEach(notes, id: \.date) { note in
                        if let i = dates.firstIndex(of: note.date), i < values.count, values.count > 1 {
                            Circle().strokeBorder(Theme.accent, lineWidth: 1.5).background(Circle().fill(Theme.paper))
                                .frame(width: 8, height: 8).position(x: x(i), y: y(v[i]))
                            Text(note.label).font(Theme.sans(10.5, .medium)).foregroundStyle(Theme.accentInk)
                                .fixedSize().position(x: min(max(x(i), 90), w - 90), y: 8)
                        }
                    }
                    if let i = hover, i < values.count, values.count > 1 {
                        Path { p in p.move(to: CGPoint(x: x(i), y: top)); p.addLine(to: CGPoint(x: x(i), y: top + h)) }
                            .stroke(color, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        if i < was.count {
                            Circle().fill(Kit.ghost).frame(width: 5, height: 5).position(x: x(i), y: y(was[i]))
                        }
                        Circle().fill(Theme.paper).overlay(Circle().strokeBorder(color, lineWidth: 2))
                            .frame(width: 10, height: 10).position(x: x(i), y: y(v[i]))
                        tip(i).position(x: kitTipX(x(i), width: 150, in: w), y: top + 34)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case .active(let p) = phase, values.count > 1, w > 0 {
                        let i = min(max(Int((p.x / w * Double(n - 1)).rounded()), 0), values.count - 1)
                        if i != hover { hover = i }
                    } else if hover != nil { hover = nil }
                }
            }
            axis(n)
        }
        .frame(height: height + 18)
    }

    private func tip(_ i: Int) -> some View {
        let was = prior.flatMap { i < $0.count ? $0[i] : nil }
        let d = was.map { values[i] - $0 }
        return ChartTip(value: "\(Signal.comma(values[i])) \(unit)", date: Signal.weekday(dates[i]).capitalized + ", " + Signal.day(dates[i]),
                        color: color,
                        change: d.map { $0 == 0 ? "same" : ($0 > 0 ? "+" : "−") + Signal.comma(abs($0)) },
                        changeTone: d.map { $0 > 0 ? .up : $0 < 0 ? .down : .flat } ?? .flat,
                        note: was.map { "vs \(Signal.comma($0)), \(prior!.count) days before" })
    }

    /// Five dates under the plot; the hovered day in the accent.
    private func axis(_ n: Int) -> some View {
        GeometryReader { g in
            let w = g.size.width - Kit.axis
            let picks = n > 4 ? [0, n / 4, n / 2, 3 * n / 4, n - 1] : Array(0..<n)
            ForEach(picks, id: \.self) { i in
                if i < dates.count {
                    Text(Signal.day(dates[i])).font(Theme.sans(10.5)).foregroundStyle(Theme.faint).fixedSize()
                        .position(x: min(max(n > 1 ? w * Double(i) / Double(n - 1) : 0, 22), w - 22), y: 6)
                        .opacity(hover.map { abs($0 - i) < max(n / 10, 1) } == true ? 0 : 1)
                }
            }
            if let i = hover, i < dates.count {
                Text(Signal.day(dates[i])).font(Theme.sans(10.5, .semibold)).foregroundStyle(Theme.accentInk).fixedSize()
                    .position(x: min(max(n > 1 ? w * Double(i) / Double(n - 1) : 0, 22), w - 22), y: 6)
            }
        }
        .frame(height: 12)
    }
}

/// Monthly bars on one axis: gray, the best month in the accent, the month still running striped.
/// Hover: a band behind the month and a tip with the change from the month before.
struct MonthBars: View {
    let points: [SocialData.Point]
    let color: Color
    var unit = "impressions"
    var height: CGFloat = 150
    @State private var hover: Int?

    var body: some View {
        let hi = max(points.map(\.value).max() ?? 1, 1)
        let ticks = Kit.ticks(Double(hi))
        let top = ticks.last ?? 1
        let running = Signal.ymd.string(from: Date()).prefix(7)
        VStack(spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                KitGrid(ticks: ticks)
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(Array(points.enumerated()), id: \.offset) { i, p in
                        let kind: KitBar.Kind = p.month.hasPrefix(running) ? .partial : p.value == hi ? .key : .rest
                        ZStack(alignment: .bottom) {
                            if hover == i { RoundedRectangle(cornerRadius: 6).fill(Kit.band) }
                            KitBar(kind: kind, color: color, hover: hover == i)
                                .frame(height: max(2, height * Double(p.value) / top))
                                .padding(.horizontal, 3)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onHover { if $0 { hover = i } else if hover == i { hover = nil } }
                    }
                }
                .padding(.trailing, Kit.axis)
                .frame(height: height, alignment: .bottom)
                if let i = hover {
                    GeometryReader { g in
                        let w = g.size.width - Kit.axis, slot = w / Double(max(points.count, 1))
                        tip(i).position(x: kitTipX(slot * (Double(i) + 0.5), width: 150, in: w, gap: slot / 2 + 4), y: 34)
                    }
                }
            }
            .frame(height: height)
            HStack(spacing: 6) {
                ForEach(Array(points.enumerated()), id: \.offset) { i, p in
                    Text(Signal.month(p.month)).font(Theme.sans(10.5, hover == i ? .semibold : .regular))
                        .foregroundStyle(hover == i ? Theme.accentInk : Theme.faint).frame(maxWidth: .infinity)
                }
            }
            .padding(.trailing, Kit.axis)
        }
    }

    private func tip(_ i: Int) -> some View {
        let p = points[i], before = i > 0 ? points[i - 1] : nil
        let running = p.month.hasPrefix(Signal.ymd.string(from: Date()).prefix(7))
        return ChartTip(value: "\(Signal.comma(p.value)) \(unit)", date: Signal.month(p.month, year: true), color: color,
                        change: running ? nil : before.flatMap { Kit.change(Double(p.value), Double($0.value)) },
                        changeTone: before.map { Kit.tone(Double(p.value), Double($0.value)) } ?? .flat,
                        note: running ? "month so far" : before.map { "vs \(Signal.month($0.month))" })
    }
}

/// LinkedIn and X per month on one scale: two bars a month, LinkedIn in its blue, X in ink.
struct DualBars: View {
    let cross: SocialData.Cross
    var height: CGFloat = 140
    @State private var hover: Int?

    var body: some View {
        let hi = max(cross.linkedin.max() ?? 1, cross.x.max() ?? 1, 1)
        let ticks = Kit.ticks(Double(hi)), top = ticks.last ?? 1
        let li = cross.linkedin.reduce(0, +), x = cross.x.reduce(0, +)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 22) {
                total("LinkedIn impressions", li, Signal.linkedin)
                total("X views", x, Signal.x)
                Spacer()
                if li > 0, x > 0 {
                    let more = li >= x ? ("LinkedIn", Double(li) / Double(x)) : ("X", Double(x) / Double(li))
                    DeltaPill(String(format: "%@ reached %.1f× more", more.0, more.1))
                }
            }
            ZStack(alignment: .bottomLeading) {
                KitGrid(ticks: ticks)
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(cross.months.indices, id: \.self) { i in
                        ZStack(alignment: .bottom) {
                            if hover == i { RoundedRectangle(cornerRadius: 6).fill(Kit.band) }
                            HStack(alignment: .bottom, spacing: 2) {
                                bar(cross.linkedin[i], top, Signal.linkedin)
                                bar(cross.x[i], top, Signal.x.opacity(0.7))
                            }
                            .padding(.horizontal, 3)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onHover { if $0 { hover = i } else if hover == i { hover = nil } }
                    }
                }
                .padding(.trailing, Kit.axis)
                if let i = hover {
                    GeometryReader { g in
                        let w = g.size.width - Kit.axis, slot = w / Double(max(cross.months.count, 1))
                        ChartTip(value: Signal.month(cross.months[i], year: true), date: "", color: Theme.muted,
                                 lines: [("LinkedIn", Signal.comma(cross.linkedin[i])), ("X", Signal.comma(cross.x[i]))])
                            .position(x: kitTipX(slot * (Double(i) + 0.5), width: 150, in: w, gap: slot / 2 + 4), y: 40)
                    }
                }
            }
            .frame(height: height)
            HStack(spacing: 8) {
                ForEach(cross.months.indices, id: \.self) { i in
                    Text(Signal.month(cross.months[i])).font(Theme.sans(10.5, hover == i ? .semibold : .regular))
                        .foregroundStyle(hover == i ? Theme.accentInk : Theme.faint).frame(maxWidth: .infinity)
                }
            }
            .padding(.trailing, Kit.axis)
        }
    }

    private func bar(_ v: Int, _ top: Double, _ c: Color) -> some View {
        KitBar(kind: .key, color: c, radius: 3).frame(height: max(2, height * Double(v) / top))
    }

    private func total(_ label: String, _ n: Int, _ c: Color) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 9, height: 9)
            Text(label).font(Theme.sans(11.5)).foregroundStyle(Theme.muted)
            Text(Signal.comma(n)).font(Theme.sans(12.5, .semibold)).foregroundStyle(Theme.ink).monospacedDigit()
        }
    }
}

/// 13 weeks × 7 days, Monday on top. Darker is more; a dot marks a day with a post; a day with
/// no reading yet is a dashed outline, never a quiet day.
struct HeatGrid: View {
    let dates: [String]
    /// nil: no data for that day yet. Drawn as an outline, never as a quiet day.
    let values: [Int?]
    let color: Color
    let unit: String
    /// Posts per day, same order as dates: a dot on each day with one.
    var posts: [Int]? = nil
    /// The cell under the pointer. One readout for the grid: a tooltip on each of the 91 cells
    /// made every scroll past the grid slow (2026-10-03).
    @State private var hover: Int?

    var body: some View {
        let hi = max(values.compactMap { $0 }.max() ?? 1, 1)
        // Pad the front so the first column starts on a Monday.
        let lead = weekdayIndex(dates.first ?? "")
        let cells: [Int??] = Array(repeating: nil, count: lead) + values.map { Optional($0) }
        let weeks = Int((Double(cells.count) / 7).rounded(.up))
        let cell: Double = 15, step: Double = 18
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .trailing, spacing: step - 14) {
                    ForEach(0..<7, id: \.self) { r in
                        Text(["Mon", "", "Wed", "", "Fri", "", "Sun"][r]).font(Theme.sans(10)).foregroundStyle(Theme.faint)
                            .frame(height: 14)
                    }
                }
                .padding(.top, 1)
                // One drawing, not 91 views: each cell as its own view made the board a thousand
                // layers for Core Animation to move on every scroll frame (2026-10-03).
                Canvas { ctx, _ in
                    for i in cells.indices {
                        let r = CGRect(x: Double(i / 7) * step, y: Double(i % 7) * step, width: cell, height: cell)
                        guard let c = cells[i] else { continue }
                        let shape = Path(roundedRect: r, cornerRadius: 3.5)
                        if let v = c {
                            ctx.fill(shape, with: .color(v == 0 ? Kit.rest.opacity(0.6) : color.opacity(0.16 + 0.84 * Double(v) / Double(hi))))
                        } else {
                            ctx.stroke(Path(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 3.5), with: .color(Kit.grid),
                                       style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        }
                        let day = i - lead
                        if let posts, day >= 0, day < posts.count, posts[day] > 0 {
                            ctx.fill(Path(ellipseIn: CGRect(x: r.midX - 2, y: r.midY - 2, width: 4, height: 4)), with: .color(Theme.paper))
                        }
                        if day == hover {
                            ctx.stroke(Path(roundedRect: r.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 4.5), with: .color(Theme.ink), lineWidth: 1.5)
                        }
                    }
                }
                .frame(width: Double(weeks) * step - (step - cell), height: 7 * step - (step - cell))
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    guard case .active(let p) = phase else { if hover != nil { hover = nil }; return }
                    let i = Int(p.x / step) * 7 + Int(p.y / step) - lead
                    let next = i >= 0 && i < dates.count ? i : nil
                    if next != hover { hover = next }
                }
            }
            HStack(spacing: 14) {
                if let i = hover {
                    readout(i)
                } else {
                    HStack(spacing: 3) {
                        Text("Less").font(Theme.sans(10.5)).foregroundStyle(Theme.faint)
                        ForEach([0.16, 0.37, 0.58, 0.79, 1.0], id: \.self) { o in
                            RoundedRectangle(cornerRadius: 2.5).fill(color.opacity(o)).frame(width: 10, height: 10)
                        }
                        Text("More").font(Theme.sans(10.5)).foregroundStyle(Theme.faint)
                    }
                    KitKey(items: [(.dashed, "No reading yet")])
                    if posts != nil {
                        HStack(spacing: 5) {
                            Circle().fill(Theme.paper).frame(width: 4, height: 4).padding(3).background(RoundedRectangle(cornerRadius: 2.5).fill(color))
                            Text("You posted").font(Theme.sans(11)).foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
            .frame(height: 18)
        }
    }

    private func readout(_ i: Int) -> some View {
        let p = posts.flatMap { i < $0.count ? $0[i] : nil } ?? 0
        return HStack(spacing: 6) {
            Text(Signal.weekday(dates[i]).capitalized + ", " + Signal.day(dates[i])).font(Theme.sans(11.5, .semibold)).foregroundStyle(Theme.ink)
            Text(values[i].map { "\(Signal.comma($0)) \(unit)" } ?? "no reading yet").font(Theme.sans(11.5)).foregroundStyle(Theme.muted)
                .monospacedDigit()
            if p > 0 { Text(p == 1 ? "· 1 post" : "· \(p) posts").font(Theme.sans(11.5)).foregroundStyle(Theme.muted) }
        }
    }

    private func weekdayIndex(_ s: String) -> Int {
        guard let d = Signal.ymd.date(from: s) else { return 0 }
        return (Calendar(identifier: .gregorian).component(.weekday, from: d) + 5) % 7  // Mon = 0
    }
}

/// Label, a bar and a number, for leaderboards and the audience. Gray; the top row in the accent.
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
                    Capsule().fill(Kit.band)
                    Capsule().fill(strong ? AnyShapeStyle(Kit.key()) : AnyShapeStyle(Kit.rest))
                        .frame(width: max(3, g.size.width * fraction))
                }
            }
            .frame(height: 6)
            Text(value).font(Theme.mono(11.5, .medium)).foregroundStyle(Theme.ink).frame(width: 48, alignment: .trailing)
            if let detail { Text(detail).font(Theme.mono(10.5)).foregroundStyle(Theme.faint).frame(width: 24, alignment: .trailing) }
        }
    }
}

/// One line of a "what's working" board: the label and its post count, then a bar with the
/// average impressions. The best one in the accent, with how far it is above the average.
struct BoardRow: View {
    let item: SocialData.Board
    let fraction: Double
    var best = false
    /// The window's average per post: the best row says "3.3× avg".
    var average: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.label).font(Theme.sans(12.5, best ? .semibold : .regular)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(item.count == 1 ? "1 post" : "\(item.count) posts").font(Theme.sans(11)).foregroundStyle(Theme.faint)
                Spacer(minLength: 6)
                if best, let average, average > 0, item.avg > average {
                    DeltaPill(String(format: "%.1f× avg", Double(item.avg) / Double(average)), tone: .up, size: 10.5)
                }
                Text(Signal.comma(item.avg)).font(Theme.mono(12, best ? .semibold : .medium)).foregroundStyle(Theme.ink)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Kit.band)
                    Capsule().fill(best ? AnyShapeStyle(Kit.key()) : AnyShapeStyle(Kit.rest))
                        .frame(width: max(4, g.size.width * fraction))
                }
            }
            .frame(height: 6)
        }
    }
}

/// Average impressions per weekday, Monday to Sunday. Gray columns, the best day in the accent,
/// a dashed line at the average. A day with no post stays a dashed slot.
struct DayBars: View {
    let items: [SocialData.Board]
    private static let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private static let names = ["Mon": "Monday", "Tue": "Tuesday", "Wed": "Wednesday", "Thu": "Thursday", "Fri": "Friday", "Sat": "Saturday", "Sun": "Sunday"]

    var body: some View {
        let byDay = Dictionary(items.map { ($0.label, $0) }, uniquingKeysWith: { a, _ in a })
        let hi = max(items.map(\.avg).max() ?? 1, 1)
        let posts = items.map(\.count).reduce(0, +)
        let mean = posts > 0 ? Double(items.map { $0.avg * $0.count }.reduce(0, +)) / Double(posts) : 0
        let best = items.max { $0.avg < $1.avg }
        let plot: CGFloat = 84
        VStack(alignment: .leading, spacing: 8) {
            if let best, mean > 0 {
                Text("\(Self.names[best.label] ?? best.label) is \(String(format: "%.1f", Double(best.avg) / mean))× your average")
                    .font(Theme.sans(11.5)).foregroundStyle(Theme.muted)
            }
            ZStack(alignment: .bottom) {
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(Self.days, id: \.self) { d in
                        let b = byDay[d]
                        VStack(spacing: 4) {
                            Text(b.map { Num.short($0.avg) } ?? "–").font(Theme.mono(10, b?.avg == hi ? .semibold : .regular))
                                .foregroundStyle(b?.avg == hi ? Theme.ink : Theme.faint)
                            KitBar(kind: b == nil ? .none : b!.avg == hi ? .key : .rest)
                                .frame(height: b.map { max(4, plot * Double($0.avg) / Double(hi)) } ?? plot * 0.25)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                if mean > 0 {
                    let y = plot * mean / Double(hi)
                    ZStack(alignment: .trailing) {
                        Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: 2000, y: 0)) }
                            .stroke(Theme.muted.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(height: 1).clipped()
                        Text("avg \(Num.short(Int(mean)))").font(Theme.sans(10, .medium)).foregroundStyle(Theme.muted)
                            .padding(.horizontal, 4).background(Theme.paper).offset(y: -8)
                    }
                    .frame(height: 1).padding(.bottom, y)
                }
            }
            .frame(height: plot + 16, alignment: .bottom)
            HStack(spacing: 8) {
                ForEach(Self.days, id: \.self) { d in
                    let b = byDay[d]
                    VStack(spacing: 1) {
                        Text(d).font(Theme.sans(11.5, b?.avg == hi ? .semibold : .regular)).foregroundStyle(Theme.ink)
                        Text(b.map { $0.count == 1 ? "1 post" : "\($0.count) posts" } ?? " ").font(Theme.sans(10)).foregroundStyle(Theme.faint)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
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
                ZStack(alignment: .leading) {
                    Capsule().fill(Kit.band)
                    Capsule().fill(post.reach >= maxReach ? AnyShapeStyle(Kit.key()) : AnyShapeStyle(Kit.rest))
                        .frame(width: max(3, g.size.width * Double(post.reach) / Double(max(maxReach, 1))))
                }
                .frame(height: 6)
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
    @AppStorage("momentumWindow") private var momentumWindow = "30"

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
                monthly("Impressions by month", "LinkedIn, the last \(data.monthly_linkedin.count) months", data.monthly_linkedin,
                        Signal.linkedin, "impressions")
                followers
                audience
            }
            if platform.isEmpty, !data.cross.months.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    ChartHeader(icon: "arrow.left.arrow.right", title: "LinkedIn vs X", subtitle: "Reach per month, on one scale")
                    DualBars(cross: data.cross)
                }
                .card(padding: 18)
            }
            if on("X") {
                if !data.monthly_x.isEmpty {
                    monthly("Views by month", "X · \(Signal.comma(data.x_totals.posts)) posts, \(Num.short(data.x_totals.views)) views all time",
                            data.monthly_x, Signal.x, "views")
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

    /// Daily reach as one card per platform: the last 30 or 90 days, the 30 before dashed.
    private var momentum: some View {
        let m = data.momentum
        return VStack(alignment: .leading, spacing: 14) {
            if on("LinkedIn") {
                chartRow("LinkedIn", "Impressions", "impressions", m.linkedin, Signal.linkedin, notes: m.annotations)
            }
            if on("X"), m.x.contains(where: { ($0 ?? 0) > 0 }) {
                // The line stops on the last day the X data covers.
                chartRow("X", "Views", "views", Array(m.x.prefix { $0 != nil }.compactMap { $0 }), Signal.x, notes: [])
            }
        }
    }

    private func chartRow(_ platform: String, _ title: String, _ unit: String, _ v: [Int], _ c: Color,
                          notes: [SocialData.Momentum.Note]) -> some View {
        let dates = data.momentum.dates
        let days = min(Int(momentumWindow) ?? 30, dates.count)
        let end = dates.count, start = end - days
        // The line runs to its last value; the window still ends on the last date.
        let cur = Array(v[min(start, v.count)..<v.count])
        let prior = start >= days && v.count >= start ? Array(v[(start - days)..<start]) : nil
        let total = cur.reduce(0, +), before = prior?.reduce(0, +)
        let posted = Set(data.heat.dates.indices.compactMap { i -> Int? in
            guard i < data.heat.li_posts.count, data.heat.li_posts[i] > 0, platform == "LinkedIn",
                  let at = dates.firstIndex(of: data.heat.dates[i]), at >= start else { return nil }
            return at - start
        })
        return VStack(alignment: .leading, spacing: 14) {
            ChartHeader(icon: "chart.xyaxis.line", title: title,
                        subtitle: "\(platform), every day" + (prior == nil ? "" : ", against the \(days) days before")) {
                HStack(spacing: 4) {
                    ForEach(["30", "90"], id: \.self) { d in
                        Button("\(d) days") { momentumWindow = d }.buttonStyle(BracketButtonStyle(active: momentumWindow == d))
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 30) {
                KitNumber(label: "\(Signal.day(dates[start])) – \(Signal.day(dates[end - 1]))", value: Signal.comma(total),
                          pill: before.flatMap { DeltaPill(now: Double(total), before: Double($0)) })
                if let before {
                    KitNumber(label: "\(Signal.day(dates[start - days])) – \(Signal.day(dates[start - 1]))", value: Signal.comma(before),
                              big: 21, tint: Theme.muted)
                }
                KitNumber(label: "Per day", value: Signal.comma(cur.isEmpty ? 0 : total / cur.count), big: 21)
                Spacer(minLength: 0)
                KitKey(items: [(.line(c), "\(days) days")] + (prior == nil ? [] : [(.dashed, "the \(days) before")]))
            }
            AreaChart(dates: Array(dates[start..<end]), values: cur, color: c, unit: unit,
                      notes: notes.filter { n in dates[start..<end].contains(n.date) }, height: 170, slots: days,
                      prior: prior, marks: posted)
        }
        .card(padding: 18)
    }

    private func stat(_ n: String, _ label: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(n).font(Theme.display(22))
            Text(label.uppercased()).font(Theme.mono(9.5)).foregroundStyle(Theme.muted)
        }
    }

    /// One grid for 13 weeks: impressions per day, a dot on each day with a post.
    private var heat: some View {
        let h = data.heat
        let active = h.impressions.filter { ($0 ?? 0) > 0 }.count
        let posts = h.li_posts.reduce(0, +)
        return VStack(alignment: .leading, spacing: 14) {
            ChartHeader(icon: "square.grid.3x3.fill", title: "13 weeks",
                        subtitle: "Impressions per day: \(active) active days, \(posts) posts on \(h.li_posts.filter { $0 > 0 }.count) days")
            HeatGrid(dates: h.dates, values: h.impressions, color: Signal.linkedin, unit: "impressions", posts: h.li_posts)
        }
        .card(padding: 18)
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
                        board("Hook type", w.by_hook, avg: w.avg)
                        board("Length", w.by_length, avg: w.avg)
                        board("Topic", w.by_topic, avg: w.avg)
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

    private func board(_ title: String, _ items: [SocialData.Board], avg: Int) -> some View {
        card(title) {
            if items.isEmpty { none } else {
                let hi = Double(max(items.map(\.avg).max() ?? 1, 1))
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, b in
                        BoardRow(item: b, fraction: Double(b.avg) / hi, best: i == 0, average: avg)
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

    /// Monthly bars in a card: the total, the best month, and the bars.
    private func monthly(_ title: String, _ sub: String, _ points: [SocialData.Point], _ c: Color, _ unit: String) -> some View {
        let best = points.max { $0.value < $1.value }
        return VStack(alignment: .leading, spacing: 14) {
            ChartHeader(icon: "chart.bar.fill", title: title, subtitle: sub)
            HStack(alignment: .bottom, spacing: 30) {
                KitNumber(label: points.first.map { "\(Signal.month($0.month, year: true)) – \(Signal.month(points.last!.month, year: true))" } ?? "",
                          value: Signal.comma(points.map(\.value).reduce(0, +)))
                if let best {
                    KitNumber(label: "Best month", value: Num.short(best.value), note: Signal.month(best.month, year: true), big: 21)
                }
                Spacer(minLength: 0)
                KitKey(items: [(.solid(Theme.accent), "Best month"), (.solid(Kit.rest), "Other months"), (.stripes, "So far")])
            }
            MonthBars(points: points, color: Theme.accent, unit: unit)
        }
        .card(padding: 18)
    }

    private var followers: some View {
        let f = data.followers
        let first = f.first?.value ?? 0, last = f.last?.value ?? 0
        return VStack(alignment: .leading, spacing: 14) {
            ChartHeader(icon: "person.2.fill", title: "Followers", subtitle: "LinkedIn, the last \(f.count) days")
            KitNumber(label: f.last.map { Signal.day($0.date) } ?? "", value: Signal.comma(last),
                      pill: DeltaPill("\(last >= first ? "+" : "−")\(Signal.comma(abs(last - first)))", tone: last > first ? .up : last < first ? .down : .flat),
                      note: f.first.map { "since \(Signal.day($0.date))" })
            AreaChart(dates: f.map(\.date), values: f.map(\.value), color: Theme.accent,
                      unit: "followers", height: 150, zeroBase: false)
        }
        .card(padding: 18)
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
