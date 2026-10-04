import SwiftUI

// The current week on the Performance board, like the phone's "This week" card (2026-10-03):
// posts against the target, the LinkedIn numbers that matter with the change from last week,
// impressions a day over last week's, this week's posts, then one line for X.

struct WeekCard: View {
    let data: SocialData
    var showX = true

    var body: some View {
        let all = data.recent + data.top_linkedin.filter { t in !data.recent.contains { $0.url == t.url } }
        let posts = Week.posts(all), before = Week.posts(all, back: 1)
        let t = Week.Totals(posts.filter { Week.settled($0, generated: data.generated) }), p = Week.Totals(before)
        let posted = max(posts.count, data.cadence.posts)
        SignalSection(label: "this week", title: Week.label()) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 6) {
                            PlatformLogo(platform: "LinkedIn", size: 13)
                            Text("LinkedIn").font(Theme.sans(12, .semibold)).foregroundStyle(Theme.muted)
                        }
                        HStack(alignment: .top, spacing: 26) {
                            stat("Impressions", Num.short(t.reach), Week.change(Double(t.reach), Double(p.reach)))
                            stat("Rate", String(format: "%.1f%%", t.rate), Week.change(t.rate, p.rate))
                            stat("Comments", "\(t.comments)", Week.change(Double(t.comments), Double(p.comments)))
                            stat("Reposts", "\(t.reposts)", Week.change(Double(t.reposts), Double(p.reposts)))
                        }
                    }
                    Spacer(minLength: 0)
                    WeekBars(heat: data.heat).frame(minWidth: 300, maxWidth: 460)
                }
                if posts.isEmpty {
                    Text(posted > 0 ? "Numbers for this week's posts come with the next update." : "Nothing posted this week yet.")
                        .font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
                } else {
                    VStack(spacing: 0) {
                        ForEach(posts.sorted { $0.date > $1.date }) { e in
                            Rule()
                            row(e)
                        }
                    }
                }
                if showX, let x = xLine { Rule(); x }
            }
            .card(padding: 16)
        } trailing: {
            HStack(spacing: 18) {
                drafts("\(data.cadence.li_drafts)", "LI drafts")
                drafts("\(data.cadence.x_drafts)", "X drafts")
                if data.cadence.target > 0 { GoalRing(posted: posted, target: data.cadence.target) }
            }
        }
    }

    private func stat(_ label: String, _ value: String, _ delta: (String, Bool)?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(Theme.mono(9.5)).foregroundStyle(Theme.muted)
            Text(value).font(Theme.display(26)).foregroundStyle(Theme.ink)
            Text(delta?.0 ?? " ").font(Theme.mono(11, .semibold))
                .foregroundStyle(delta?.1 ?? true ? Theme.live : Theme.danger)
        }
    }

    private func drafts(_ n: String, _ label: String) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(n).font(Theme.sans(14, .semibold)).foregroundStyle(Theme.ink)
            Text(label.uppercased()).font(Theme.mono(9)).foregroundStyle(Theme.muted)
        }
    }

    private func row(_ e: SocialData.Entry) -> some View {
        HStack(spacing: 12) {
            Text(Signal.weekday(e.date)).font(Theme.mono(10.5, .medium)).foregroundStyle(Theme.muted)
                .frame(width: 34, alignment: .leading)
            Text(e.title).font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if Week.settled(e, generated: data.generated) {
                if let c = e.comments { Text("\(c) comments").font(Theme.mono(11)).foregroundStyle(Theme.muted) }
                Text(Signal.comma(e.reach)).font(Theme.mono(12, .semibold)).foregroundStyle(Theme.ink)
                    .frame(width: 56, alignment: .trailing)
            } else {
                Text("New").font(Theme.sans(10.5, .semibold)).foregroundStyle(Theme.accentInk)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Theme.accentSoft, in: Capsule())
                    .help("Still collecting its first numbers: left out of the totals for two days")
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { if let u = URL(string: e.url), !e.url.isEmpty { NSWorkspace.shared.open(u) } }
    }

    /// X this week: posts and views, against last week.
    private var xLine: AnyView? {
        let h = data.heat, m = data.momentum
        let posts = { (days: [String]) in
            days.reduce(0) { n, d in n + (h.dates.firstIndex(of: d).flatMap { $0 < h.x_posts.count ? h.x_posts[$0] : nil } ?? 0) }
        }
        let views = { (days: [String]) in
            days.reduce(0) { n, d in n + (m.dates.firstIndex(of: d).flatMap { $0 < m.x.count ? m.x[$0] : nil } ?? 0) }
        }
        let now = Week.days(), prev = Week.days(back: 1)
        let n = posts(now), v = views(now)
        guard n > 0 || v > 0 else { return nil }
        let delta = Week.change(Double(v), Double(views(prev)))
        return AnyView(HStack(spacing: 8) {
            PlatformLogo(platform: "X", size: 13)
            Text(n == 1 ? "1 post" : "\(n) posts").font(Theme.sans(12.5, .semibold)).foregroundStyle(Theme.ink)
            Spacer()
            Text("\(Num.short(v)) views").font(Theme.mono(12)).foregroundStyle(Theme.ink)
            if let delta {
                Text(delta.0).font(Theme.mono(11, .semibold)).foregroundStyle(delta.1 ? Theme.live : Theme.danger)
            }
        })
    }
}

/// "5/3 posts" as a ring that fills toward the weekly target.
struct GoalRing: View {
    let posted: Int
    let target: Int

    var body: some View {
        ZStack {
            Circle().stroke(Theme.border, lineWidth: 4)
            Circle().trim(from: 0, to: min(1, Double(posted) / Double(target)))
                .stroke(posted >= target ? Theme.live : Theme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -1) {
                Text("\(posted)/\(target)").font(Theme.sans(12, .bold)).monospacedDigit().foregroundStyle(Theme.ink)
                Text("posts").font(Theme.sans(8)).foregroundStyle(Theme.muted)
            }
        }
        .frame(width: 46, height: 46)
        .help(posted >= target ? "On target this week" : "\(target - posted) to go this week")
    }
}

/// LinkedIn impressions a day, Monday to Sunday, over last week's in grey. A dot marks a day
/// with a post.
struct WeekBars: View {
    let heat: SocialData.Heat

    var body: some View {
        let at = Dictionary(heat.dates.indices.map { (heat.dates[$0], $0) }, uniquingKeysWith: { a, _ in a })
        let value = { (d: String) -> Int? in at[d].flatMap { $0 < heat.impressions.count ? heat.impressions[$0] : nil } }
        let now = Week.days(), prev = Week.days(back: 1)
        let hi = max((now + prev).compactMap(value).max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(0..<7, id: \.self) { i in
                let v = value(now[i]), was = value(prev[i])
                let posted = (at[now[i]].flatMap { $0 < heat.li_posts.count ? heat.li_posts[$0] : nil } ?? 0) > 0
                VStack(spacing: 4) {
                    Text(v.map { Num.short($0) } ?? " ").font(Theme.mono(9)).foregroundStyle(Theme.muted)
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 3).fill(Theme.border)
                            .frame(height: was.map { max(2, 70 * Double($0) / Double(hi)) } ?? 0)
                        RoundedRectangle(cornerRadius: 3).fill(Signal.linkedin)
                            .frame(width: 14, height: v.map { max(2, 70 * Double($0) / Double(hi)) } ?? 0)
                    }
                    .frame(height: 70, alignment: .bottom)
                    Text(["M", "T", "W", "T", "F", "S", "S"][i]).font(Theme.mono(10)).foregroundStyle(Theme.muted)
                    Circle().fill(posted ? Signal.linkedin : .clear).frame(width: 4, height: 4)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .help("LinkedIn impressions a day. Grey: last week. A dot: a post that day.")
    }
}

/// Week maths, shared by the card and its tests.
enum Week {
    private static let cal = Calendar(identifier: .iso8601)

    /// The days of a week (Monday first) as yyyy-MM-dd. `back` 1 is last week.
    static func days(back: Int = 0, now: Date = Date()) -> [String] {
        guard let monday = cal.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0 - 7 * back, to: monday).map(Signal.ymd.string) }
    }

    /// The posts of a week, Monday to Sunday.
    static func posts(_ list: [SocialData.Entry], back: Int = 0, now: Date = Date()) -> [SocialData.Entry] {
        let d = Set(days(back: back, now: now))
        var seen = Set<String>()
        return list.filter { d.contains(String($0.date.prefix(10))) && seen.insert($0.url).inserted }
    }

    /// A post younger than two days is still collecting its first numbers: 90 views can show a
    /// 20% rate. It shows in the list but stays out of the totals.
    static func settled(_ e: SocialData.Entry, generated: String) -> Bool {
        guard let d = Signal.ymd.date(from: String(e.date.prefix(10))),
              let g = Signal.ymd.date(from: String(generated.prefix(10))) else { return true }
        return (Calendar.current.dateComponents([.day], from: d, to: g).day ?? 0) >= 2
    }

    struct Totals {
        var reach = 0, engagements = 0, comments = 0, reposts = 0
        var rate: Double { reach > 0 ? Double(engagements) / Double(reach) * 100 : 0 }
        init(_ list: [SocialData.Entry]) {
            for e in list {
                reach += e.reach; engagements += e.engagements
                comments += e.comments ?? 0; reposts += e.reposts ?? 0
            }
        }
    }

    /// "+24%" against last week, or nil when last week had nothing to compare.
    static func change(_ now: Double, _ before: Double) -> (String, Bool)? {
        guard before > 0 else { return nil }
        let pct = Int(((now - before) / before * 100).rounded())
        return ("\(pct >= 0 ? "+" : "")\(pct)%", pct >= 0)
    }

    /// "Sep 28 – Oct 4".
    static func label(_ now: Date = Date()) -> String {
        let d = days(now: now)
        guard let a = d.first, let b = d.last else { return "" }
        return "\(Signal.day(a)) – \(Signal.day(b))"
    }
}
