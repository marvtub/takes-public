import Charts
import SwiftUI

// The performance board from the Mac, for the phone: the Signal dashboard numbers
// (_library/social.json) and the latest numbers of every post published from Takes.

struct PerformanceView: View {
    @EnvironmentObject var model: Model
    @State private var data: Performance?
    @State private var failed: String?
    /// Which top posts to show: "30", "60" or "90" days, or "all" time.
    @AppStorage("topWindow") private var topWindow = "60"
    @Environment(\.openURL) private var openURL
    @State private var chatOpen = false
    /// The Update ask is on its way to the Mac, or the Mac said no.
    @State private var sending = false
    @State private var problem: String?
    @State private var audienceGroup = 0
    /// The activity grid shows one network at a time: X has replies most days, LinkedIn a post a few times a week.
    @AppStorage("activityPlatform") private var activityX = false

    static let chatID = "board:performance"
    static let updateAsk = "Update the numbers: refresh the social data as the runbook says, until no source is OLD and no post is NEED. I'm on my phone."

    var body: some View {
        ScrollView {
            ScreenHeader(title: "") {
                Button { chatOpen = true } label: { RoundIcon(icon: "bubble.left.and.text.bubble.right", label: "Performance chat") }
                    .buttonStyle(.press)
            } trailing: {
                Button { Task { await update() } } label: {
                    HStack(spacing: 6) {
                        if model.performanceRunning || sending { WorkingDots(color: .white) } else {
                            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 14, weight: .semibold))
                            Text("Update")
                        }
                    }
                    .font(.inter(.subheadline, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: 34)
                    .background(Palette.accent, in: Capsule())
                }
                .buttonStyle(.press)
                .disabled(model.performanceRunning || sending)
            }
            if let data {
                VStack(alignment: .leading, spacing: 20) {
                    updating
                    if let s = data.social { social(s) }
                    published(data.posts)
                }
                .padding(16)
            } else if let failed {
                MascotEmpty(title: "Can't load the numbers", message: failed, mood: .sorry)
            } else {
                WorkingDots().padding(.top, 80)
            }
        }
        .background(Palette.canvas.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await load() }
        .withTabBar()
        .navigationDestination(isPresented: $chatOpen) {
            BoardChatView(id: Self.chatID, title: "Performance",
                          empty: "Ask about your numbers, or tap Update to have Takes refresh them on the Mac.")
        }
        .onChange(of: model.performanceTick) { _, _ in Task { await load() } }
        .task {
            // Last time's numbers at once, then the Mac's.
            if data == nil, let raw = Cache.loadData("performance") { data = try? API.decoder.decode(Performance.self, from: raw) }
            await load()
        }
    }

    private func load() async {
        do {
            let raw = try await model.api.performanceData()
            data = try API.decoder.decode(Performance.self, from: raw)
            Cache.saveData(raw, "performance")
            failed = nil
        } catch {
            if data == nil { failed = error.localizedDescription }
        }
    }

    /// Claude updates the numbers on the Mac (its Performance chat). Tap to watch.
    private func update() async {
        problem = nil
        sending = true
        let ok = await model.say(Self.updateAsk, in: Self.chatID, from: "Performance")
        sending = false
        if ok {
            model.performanceRunning = true
            chatOpen = true
        } else {
            problem = model.error ?? "The Mac didn't answer."
            model.error = nil
        }
    }

    @ViewBuilder private var updating: some View {
        if sending {
            HStack(spacing: 10) {
                WorkingDots()
                Text("Asking Takes on your Mac").font(.inter(.subheadline, .medium))
                Spacer()
            }
            .foregroundStyle(Palette.ink)
            .padding(14)
            .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else if let problem {
            VStack(alignment: .leading, spacing: 8) {
                Label("Couldn't start the update", systemImage: "exclamationmark.triangle.fill")
                    .font(.inter(.subheadline, .semibold)).foregroundStyle(Palette.danger)
                Text("\(problem)\nIf Takes on the Mac is from before today, quit and open it again: older versions have no Performance chat.")
                    .font(.inter(.footnote)).foregroundStyle(Palette.muted)
                HStack {
                    Button("Try again") { Task { await update() } }.buttonStyle(.pill(small: true))
                    Spacer()
                    Button("Dismiss") { self.problem = nil }.buttonStyle(.pill(.quiet, small: true))
                }
            }
            .padding(14)
            .background(Palette.dangerSoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else if model.performanceRunning {
            Button { chatOpen = true } label: {
                HStack(spacing: 10) {
                    WorkingDots()
                    Text("Takes is updating the numbers").font(.inter(.subheadline, .medium))
                    Spacer()
                    Text("Watch").font(.inter(.subheadline, .semibold)).foregroundStyle(Palette.accent)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.accent)
                }
                .foregroundStyle(Palette.ink)
                .padding(14)
                .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(Pressable(scale: 0.98))
        }
    }

    // MARK: Signal

    @ViewBuilder private func social(_ s: Performance.Social) -> some View {
        let h = s.hero
        freshness(s)
        hero(h)
        thisWeek(s)
        if let m = s.momentum, !m.dates.isEmpty { momentum(m) }
        if let f = s.followers, f.filter({ $0.value != nil }).count > 1 { followers(f) }
        if let h = s.heat, !h.dates.isEmpty { activity(h, s.momentum) }
        if let ml = s.monthly_linkedin, !ml.isEmpty { monthly(ml, x: s.monthly_x ?? []) }
        if s.top_linkedin?.isEmpty == false || s.top_linkedin_windows != nil {
            let top = topWindow == "all" ? s.top_linkedin ?? [] : s.top_linkedin_windows?[topWindow] ?? []
            HStack(spacing: 6) { PlatformLogo(kind: .linkedin, size: 16); Text("Top LinkedIn posts").font(.headline) }.padding(.top, 4)
            Segments(items: ["30", "60", "90", "all"], selection: $topWindow) { $0 == "all" ? "All time" : "\($0) days" }
            if top.isEmpty {
                Text(s.top_linkedin_windows == nil ? "Refresh the numbers on the Mac to see this period."
                                                   : "No posts in the last \(topWindow) days.")
                    .font(.inter(.subheadline)).foregroundStyle(Palette.muted).padding(.vertical, 8)
            }
            ForEach(Array(top.prefix(5).enumerated()), id: \.element.id) { i, e in
                FeedCard(entry: e, rank: i + 1, profile: data?.profile)
            }
        }
        if let recent = s.recent, !recent.isEmpty { entries("Recent posts", Array(recent.prefix(8))) }
        if let a = s.audience, !a.isEmpty { audience(a) }
    }

    /// "Updated 3 hours ago", then the last day each source covers. Over a day old, it turns orange.
    @ViewBuilder private func freshness(_ s: Performance.Social) -> some View {
        let at = Self.updated(s)
        VStack(alignment: .leading, spacing: 2) {
            if let at {
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    Label("Updated \(at.formatted(.relative(presentation: .named)))", systemImage: "clock")
                        .font(.inter(.subheadline, .semibold))
                        .foregroundStyle(Date().timeIntervalSince(at) > 86400 ? .orange : Palette.ink)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// sources.refreshed ("2026-10-02 18:01"), else when the Mac wrote the numbers.
    static func updated(_ s: Performance.Social) -> Date? {
        if let r = s.sources?.refreshed {
            if let d = Fmt.minute.date(from: r) { return d }
        }
        return Dates.plain.date(from: s.generated)
    }

    private func momentum(_ m: Performance.Social.Momentum) -> some View {
        let n = min(60, m.dates.count)
        let start = m.dates.count - n
        // X reaches 10x the LinkedIn numbers, so each gets its own axis: LinkedIn on the left,
        // X drawn at `k` times its value and labelled in its own numbers on the right.
        let li = (start..<min(m.dates.count, m.linkedin.count)).map { m.linkedin[$0] }
        let xs = (start..<min(m.dates.count, m.x.count)).compactMap { m.x[$0] }
        let liTop = Self.nice(Double(li.max() ?? 0))
        // One viral X day (19.8k on Sep 2) would flatten every other day: the axis follows the
        // second-highest day when the highest is more than twice it, and the spike stops at the top.
        let xsSorted = xs.sorted(by: >)
        let xPeak = xsSorted.count > 1 && xsSorted[0] > 2 * xsSorted[1] ? xsSorted[1] : xsSorted.first ?? 0
        let xTop = Self.nice(Double(xPeak))
        let k = xTop > 0 ? liTop / xTop : 1
        // Round steps: 0-5k in 1k, 0-2k in 500.
        let parts = liTop / pow(10, floor(log10(liTop))) == 2 ? 4 : 5
        let ticks = (0...parts).map { liTop * Double($0) / Double(parts) }
        return card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HStack(spacing: 4) { PlatformLogo(kind: .linkedin, size: 13); Text("LinkedIn").foregroundStyle(Self.liBlue) }
                    Spacer()
                    Text("Impressions a day, last \(n) days").foregroundStyle(Palette.muted)
                    Spacer()
                    HStack(spacing: 4) { Text("X").foregroundStyle(Palette.ink); PlatformLogo(kind: .x, size: 13) }
                }
                .font(.inter(.caption))
                Chart {
                    ForEach(start..<m.dates.count, id: \.self) { i in
                        if let d = Self.day(m.dates[i]) {
                            if i < m.linkedin.count {
                                AreaMark(x: .value("Day", d), y: .value("Impressions", Double(m.linkedin[i])), series: .value("Source", "LinkedIn"))
                                    .foregroundStyle(Self.liBlue.opacity(0.35))
                                LineMark(x: .value("Day", d), y: .value("Impressions", Double(m.linkedin[i])), series: .value("Source", "LinkedIn"))
                                    .foregroundStyle(Self.liBlue).lineStyle(StrokeStyle(lineWidth: 1.5))
                            }
                            if i < m.x.count, let x = m.x[i] {
                                LineMark(x: .value("Day", d), y: .value("Impressions", min(Double(x), xTop) * k), series: .value("Source", "X"))
                                    .foregroundStyle(Palette.ink).lineStyle(StrokeStyle(lineWidth: 1.5))
                            }
                        }
                    }
                }
                .chartYScale(domain: 0...max(liTop, 1))
                .chartYAxis {
                    AxisMarks(position: .leading, values: ticks) { v in
                        AxisGridLine()
                        AxisValueLabel { Text(Self.short(v.as(Double.self) ?? 0)).foregroundStyle(Self.liBlue) }
                    }
                    AxisMarks(position: .trailing, values: ticks) { v in
                        AxisValueLabel { Text(Self.short((v.as(Double.self) ?? 0) / k)).foregroundStyle(Palette.ink) }
                    }
                }
                .frame(height: 170)
            }
        }
    }

    static let liBlue = Color(red: 0.04, green: 0.4, blue: 0.76)

    // MARK: This week

    /// The LinkedIn posts of a week (Monday to Sunday), from the recent list. `back` 1 is last week.
    static func week(_ list: [Performance.Social.Entry], back: Int = 0, now: Date = Date()) -> [Performance.Social.Entry] {
        let cal = Calendar(identifier: .iso8601)
        guard let thisMonday = cal.dateInterval(of: .weekOfYear, for: now)?.start,
              let start = cal.date(byAdding: .day, value: -7 * back, to: thisMonday),
              let end = cal.date(byAdding: .day, value: 7, to: start) else { return [] }
        return list.filter { e in Self.day(e.date).map { $0 >= start && $0 < end } ?? false }
    }

    /// A post younger than two days is still collecting its first numbers: 90 views can show a
    /// 20% rate. It shows in the list but stays out of the totals.
    static func settled(_ e: Performance.Social.Entry, generated: String) -> Bool {
        guard let d = day(e.date), let g = day(generated) else { return true }
        return (Calendar.current.dateComponents([.day], from: d, to: g).day ?? 0) >= 2
    }

    struct Totals {
        var reach = 0, engagements = 0, comments = 0, reposts = 0
        var rate: Double { reach > 0 ? Double(engagements) / Double(reach) * 100 : 0 }
        init(_ list: [Performance.Social.Entry]) {
            for e in list {
                reach += e.reach; engagements += e.engagements
                comments += e.comments ?? 0; reposts += e.reposts ?? 0
            }
        }
    }

    /// The days of a week (Monday first) as yyyy-MM-dd. `back` 1 is last week.
    static func weekDays(back: Int = 0, now: Date = Date()) -> [String] {
        let cal = Calendar(identifier: .iso8601)
        guard let monday = cal.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0 - 7 * back, to: monday).map(Fmt.day.string) }
    }

    /// This week at a glance: posts against the target, the LinkedIn numbers that matter (impressions,
    /// rate, comments, reposts) with the change from last week, a bar a day, the posts, then X.
    @ViewBuilder private func thisWeek(_ s: Performance.Social) -> some View {
        let all = (s.recent ?? []) + (s.top_linkedin ?? []).filter { t in !(s.recent ?? []).contains { $0.url == t.url } }
        let posts = Self.week(all), prevPosts = Self.week(all, back: 1)
        let t = Totals(posts.filter { Self.settled($0, generated: s.generated) }), p = Totals(prevPosts)
        let posted = max(posts.count, s.cadence?.posts ?? 0)
        let target = s.cadence?.target ?? 0
        card {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("This week").font(.nunito(.headline))
                        Text(Self.weekLabel()).font(.inter(.caption)).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    if target > 0 { goal(posted, target) }
                }
                HStack(spacing: 6) {
                    PlatformLogo(kind: .linkedin, size: 14)
                    Text("LinkedIn").font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
                }
                HStack(alignment: .top, spacing: 0) {
                    stat("Impressions", Self.short(Double(t.reach)), Self.change(Double(t.reach), Double(p.reach)))
                    stat("Rate", String(format: "%.1f%%", t.rate), Self.change(t.rate, p.rate))
                    stat("Comments", "\(t.comments)", Self.change(Double(t.comments), Double(p.comments)))
                    stat("Reposts", "\(t.reposts)", Self.change(Double(t.reposts), Double(p.reposts)))
                }
                if let h = s.heat { weekBars(h) }
                if !posts.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(posts.sorted { $0.date > $1.date }) { e in
                            Divider()
                            Button { if let u = URL(string: e.url) { openURL(u) } } label: {
                                HStack(spacing: 10) {
                                    Text(Self.weekday(e.date)).font(.inter(.caption, .semibold)).foregroundStyle(Palette.faint)
                                        .frame(width: 30, alignment: .leading)
                                    Text(e.title).font(.inter(.subheadline)).foregroundStyle(Palette.ink).lineLimit(1)
                                    Spacer(minLength: 6)
                                    if Self.settled(e, generated: s.generated) {
                                        Text(Self.short(Double(e.reach))).font(.inter(.subheadline, .semibold).monospacedDigit())
                                            .foregroundStyle(Palette.ink)
                                    } else {
                                        Text("New").font(.inter(.caption2, .semibold)).foregroundStyle(Palette.accent)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Palette.accent.opacity(0.12), in: Capsule())
                                    }
                                }
                                .padding(.vertical, 9)
                            }
                        }
                    }
                } else {
                    Text(posted > 0 ? "Numbers for this week's posts come with the next update." : "Nothing posted this week yet.")
                        .font(.inter(.subheadline)).foregroundStyle(Palette.muted)
                }
                if let x = xWeek(s) { x }
            }
        }
    }

    /// The posts ring: "5/3".
    private func goal(_ posted: Int, _ target: Int) -> some View {
        ZStack {
            Circle().stroke(Palette.border, lineWidth: 4)
            Circle().trim(from: 0, to: min(1, Double(posted) / Double(target)))
                .stroke(posted >= target ? Palette.live : Palette.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -2) {
                Text("\(posted)/\(target)").font(.system(size: 13, weight: .bold).monospacedDigit()).foregroundStyle(Palette.ink)
                Text("posts").font(.system(size: 8)).foregroundStyle(Palette.muted)
            }
        }
        .frame(width: 46, height: 46)
    }

    /// LinkedIn impressions a day, Monday to Sunday, over last week's in grey.
    private func weekBars(_ h: Performance.Social.Heat) -> some View {
        let at = Dictionary(h.dates.indices.map { (h.dates[$0], $0) }, uniquingKeysWith: { a, _ in a })
        let value = { (d: String) -> Int? in at[d].flatMap { $0 < h.impressions.count ? h.impressions[$0] : nil } }
        let posted = { (d: String) -> Bool in at[d].flatMap { $0 < h.li_posts.count ? h.li_posts[$0] : nil } ?? 0 > 0 }
        let now = Self.weekDays(), prev = Self.weekDays(back: 1)
        let names = ["M", "T", "W", "T", "F", "S", "S"]
        return Chart {
            ForEach(0..<7, id: \.self) { i in
                if let v = value(prev[i]) {
                    BarMark(x: .value("Day", "\(i)"), y: .value("Impressions", v), width: .ratio(0.7))
                        .foregroundStyle(Palette.border).cornerRadius(3)
                }
                if let v = value(now[i]) {
                    BarMark(x: .value("Day", "\(i)"), y: .value("Impressions", v), width: .ratio(0.42))
                        .foregroundStyle(Self.liBlue).cornerRadius(3)
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: (0..<7).map { "\($0)" }) { v in
                AxisValueLabel {
                    let i = Int(v.as(String.self) ?? "") ?? 0
                    VStack(spacing: 2) {
                        Text(names[i]).font(.inter(.caption2)).foregroundStyle(Palette.faint)
                        Circle().fill(posted(now[i]) ? Self.liBlue : .clear).frame(width: 4, height: 4)
                    }
                }
            }
        }
        .chartYAxis(.hidden)
        .frame(height: 90)
    }

    /// X this week: posts and impressions, against last week.
    private func xWeek(_ s: Performance.Social) -> AnyView? {
        guard let h = s.heat else { return nil }
        let posts = { (days: [String]) -> Int in
            days.reduce(0) { n, d in n + (h.dates.firstIndex(of: d).flatMap { $0 < h.x_posts.count ? h.x_posts[$0] : nil } ?? 0) }
        }
        let views = { (days: [String]) -> Int in
            guard let m = s.momentum else { return 0 }
            return days.reduce(0) { n, d in n + (m.dates.firstIndex(of: d).flatMap { $0 < m.x.count ? m.x[$0] : nil } ?? 0) }
        }
        let now = Self.weekDays(), prev = Self.weekDays(back: 1)
        let n = posts(now), v = views(now)
        guard n > 0 || v > 0 else { return nil }
        let delta = Self.change(Double(v), Double(views(prev)))
        return AnyView(VStack(spacing: 0) {
            Divider().padding(.bottom, 12)
            HStack(spacing: 8) {
                PlatformLogo(kind: .x, size: 14)
                Text("\(n) posts").font(.inter(.subheadline, .semibold)).foregroundStyle(Palette.ink)
                Spacer()
                Text("\(Self.short(Double(v))) impressions").font(.inter(.subheadline).monospacedDigit()).foregroundStyle(Palette.ink)
                if let delta {
                    Text(delta.0).font(.inter(.caption, .semibold).monospacedDigit()).foregroundStyle(delta.1 ? Palette.live : .red)
                }
            }
        })
    }

    private func stat(_ label: String, _ value: String, _ delta: (String, Bool)?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.inter(.caption)).foregroundStyle(Palette.muted).lineLimit(1)
            Text(value).font(.nunito(.title3).monospacedDigit()).foregroundStyle(Palette.ink).lineLimit(1)
            Text(delta?.0 ?? " ").font(.inter(.caption2, .semibold).monospacedDigit())
                .foregroundStyle(delta?.1 ?? true ? Palette.live : .red)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "+24%" against last week, or nil when last week had nothing to compare.
    static func change(_ now: Double, _ before: Double) -> (String, Bool)? {
        guard before > 0 else { return nil }
        let pct = Int(((now - before) / before * 100).rounded())
        return ("\(pct >= 0 ? "+" : "")\(pct)%", pct >= 0)
    }

    /// "Sep 28 – Oct 4".
    static func weekLabel(_ now: Date = Date()) -> String {
        let cal = Calendar(identifier: .iso8601)
        guard let w = cal.dateInterval(of: .weekOfYear, for: now) else { return "" }
        return "\(Fmt.monthDay.string(from: w.start)) – \(Fmt.monthDay.string(from: w.end.addingTimeInterval(-1)))"
    }

    static func weekday(_ s: String) -> String {
        guard let d = day(s) else { return "" }
        return Fmt.weekday.string(from: d)
    }

    // MARK: Followers

    private func followers(_ pts: [Performance.Social.Point]) -> some View {
        let days = pts.compactMap { p -> (Date, Int)? in
            guard let d = Self.day(p.date), let v = p.value else { return nil }
            return (d, v)
        }
        let first = days.first?.1 ?? 0, last = days.last?.1 ?? 0
        let lo = Double(days.map(\.1).min() ?? 0), hi = Double(days.map(\.1).max() ?? 0)
        let pad = max(5, (hi - lo) * 0.15)
        return card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Followers").font(.nunito(.headline))
                        Text("Last \(days.count > 1 ? Self.span(days.first!.0, days.last!.0) : "days")").font(.inter(.caption)).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(last.formatted()).font(.nunito(.title3).monospacedDigit())
                        Text("\(last - first >= 0 ? "+" : "")\(last - first)").font(.inter(.caption, .semibold).monospacedDigit())
                            .foregroundStyle(last >= first ? Palette.live : .red)
                    }
                }
                Chart(days, id: \.0) { d, v in
                    AreaMark(x: .value("Day", d), yStart: .value("Base", lo - pad), yEnd: .value("Followers", Double(v)))
                        .foregroundStyle(LinearGradient(colors: [Palette.accent.opacity(0.28), Palette.accent.opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Day", d), y: .value("Followers", Double(v)))
                        .foregroundStyle(Palette.accent).lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)
                }
                .chartYScale(domain: (lo - pad)...(hi + pad))
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine()
                    AxisValueLabel { Text(Self.short(v.as(Double.self) ?? 0)) }
                } }
                .chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
                .frame(height: 150)
            }
        }
    }

    static func span(_ a: Date, _ b: Date) -> String {
        let d = max(1, Calendar.current.dateComponents([.day], from: a, to: b).day ?? 0)
        return "\(d) days"
    }

    // MARK: Activity

    /// GitHub-style: one square a day for 13 weeks, darker for more impressions, a dot on days you
    /// posted. LinkedIn or X, never both added up.
    private func activity(_ h: Performance.Social.Heat, _ m: Performance.Social.Momentum?) -> some View {
        let cal = Calendar(identifier: .iso8601)
        let xViews = Dictionary((m?.dates.indices ?? 0..<0).map { (m!.dates[$0], $0 < m!.x.count ? m!.x[$0] : nil) },
                                uniquingKeysWith: { a, _ in a })
        let days = h.dates.indices.compactMap { i -> (Date, Int, Int)? in
            guard let d = Self.day(h.dates[i]) else { return nil }
            let posts = activityX ? (i < h.x_posts.count ? h.x_posts[i] : nil) ?? 0 : (i < h.li_posts.count ? h.li_posts[i] : nil) ?? 0
            let views = activityX ? (xViews[h.dates[i]] ?? nil) ?? 0 : (i < h.impressions.count ? h.impressions[i] : nil) ?? 0
            return (d, views, posts)
        }
        let tint = activityX ? Palette.ink : Self.liBlue
        // Columns are weeks starting Monday; the first column starts on the first day's Monday.
        let start = days.first.map { cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: $0.0)) ?? $0.0 } ?? Date()
        let byDay = Dictionary(days.map { (cal.startOfDay(for: $0.0), ($0.1, $0.2)) }, uniquingKeysWith: { a, _ in a })
        let weeks = days.last.map { (cal.dateComponents([.day], from: start, to: $0.0).day ?? 0) / 7 + 1 } ?? 0
        let sorted = days.map(\.1).filter { $0 > 0 }.sorted()
        let q = { (f: Double) in sorted.isEmpty ? 1 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * f))] }
        let steps = [q(0.25), q(0.5), q(0.75), q(0.92)]
        let level = { (v: Int) -> Int in v <= 0 ? 0 : 1 + steps.filter { v > $0 }.count }
        let posted = days.filter { $0.2 > 0 }.count
        let total = days.reduce(0) { $0 + $1.1 }
        return card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Activity").font(.nunito(.headline))
                    Spacer()
                    HStack(spacing: 2) {
                        ForEach([false, true], id: \.self) { x in
                            Button { Brand.select(); withAnimation(Brand.quick) { activityX = x } } label: {
                                HStack(spacing: 5) {
                                    PlatformLogo(kind: x ? .x : .linkedin, size: 14)
                                    Text(x ? "X" : "LinkedIn").font(.caption.weight(.semibold))
                                }
                                .foregroundStyle(activityX == x ? Palette.ink : Palette.muted)
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(activityX == x ? Palette.paper : .clear, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2).background(Palette.well, in: Capsule())
                }
                Text("\(posted) posting days · \(Self.short(Double(total))) impressions").font(.inter(.caption)).foregroundStyle(Palette.muted)
                GeometryReader { g in
                    let gap: CGFloat = 3
                    let side = min(18, (g.size.width - 18 - gap * CGFloat(max(weeks - 1, 0))) / CGFloat(max(weeks, 1)))
                    HStack(alignment: .top, spacing: gap) {
                        VStack(alignment: .trailing, spacing: gap) {
                            ForEach(0..<7, id: \.self) { r in
                                Text(r % 2 == 0 ? ["M", "", "W", "", "F", "", "S"][r] : "").font(.system(size: 8)).foregroundStyle(Palette.faint)
                                    .frame(width: 12, height: side)
                            }
                        }
                        ForEach(0..<weeks, id: \.self) { w in
                            VStack(spacing: gap) {
                                ForEach(0..<7, id: \.self) { r in
                                    let d = cal.date(byAdding: .day, value: w * 7 + r, to: start) ?? start
                                    let cell = byDay[cal.startOfDay(for: d)]
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(cell == nil ? Color.clear : Self.heatColor(level(cell!.0), tint))
                                        .overlay { if let c = cell, c.1 > 0 { Circle().fill(activityX ? Palette.paper : .white).frame(width: side * 0.3) } }
                                        .frame(width: side, height: side)
                                }
                            }
                        }
                    }
                }
                .frame(height: 7 * 18 + 6 * 3)
                HStack(spacing: 4) {
                    Circle().fill(Palette.muted).frame(width: 5)
                    Text("you posted").font(.inter(.caption2)).foregroundStyle(Palette.muted)
                    Spacer()
                    Text("Less").font(.inter(.caption2)).foregroundStyle(Palette.faint)
                    ForEach(0..<5, id: \.self) { RoundedRectangle(cornerRadius: 2).fill(Self.heatColor($0, tint)).frame(width: 10, height: 10) }
                    Text("More").font(.inter(.caption2)).foregroundStyle(Palette.faint)
                }
            }
        }
    }

    static func heatColor(_ level: Int, _ tint: Color) -> Color {
        level == 0 ? Palette.border.opacity(0.7) : tint.opacity([0, 0.25, 0.45, 0.7, 1][min(level, 4)])
    }

    // MARK: Monthly

    private func monthly(_ li: [Performance.Social.MonthValue], x: [Performance.Social.MonthValue]) -> some View {
        let xs = Dictionary(x.map { ($0.month, $0.value) }, uniquingKeysWith: { a, _ in a })
        return card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Impressions by month").font(.nunito(.headline))
                    Spacer()
                    HStack(spacing: 10) {
                        HStack(spacing: 4) { PlatformLogo(kind: .linkedin, size: 13); Text("LinkedIn").foregroundStyle(Self.liBlue) }
                        HStack(spacing: 4) { PlatformLogo(kind: .x, size: 13); Text("X").foregroundStyle(Palette.ink) }
                    }
                    .font(.inter(.caption2))
                }
                Chart {
                    ForEach(li, id: \.month) { m in
                        BarMark(x: .value("Month", Self.month(m.month)), y: .value("Impressions", m.value))
                            .foregroundStyle(Self.liBlue).position(by: .value("Source", "LinkedIn"))
                        if let v = xs[m.month] {
                            BarMark(x: .value("Month", Self.month(m.month)), y: .value("Impressions", v))
                                .foregroundStyle(Palette.ink.opacity(0.75)).position(by: .value("Source", "X"))
                        }
                    }
                }
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine()
                    AxisValueLabel { Text(Self.short(v.as(Double.self) ?? 0)) }
                } }
                .frame(height: 160)
            }
        }
    }

    // MARK: Audience

    private func audience(_ groups: [Performance.Social.Audience]) -> some View {
        let g = groups[min(audienceGroup, groups.count - 1)]
        return card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Audience").font(.nunito(.headline))
                    Spacer()
                    Menu {
                        ForEach(groups.indices, id: \.self) { i in Button(groups[i].title) { audienceGroup = i } }
                    } label: {
                        HStack(spacing: 3) { Text(g.title); Image(systemName: "chevron.up.chevron.down").imageScale(.small) }
                            .font(.inter(.subheadline))
                    }
                }
                let top = g.items.map(\.pct).max() ?? 1
                ForEach(g.items.prefix(6), id: \.label) { it in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(it.label).font(.inter(.subheadline)).foregroundStyle(Palette.ink).lineLimit(1)
                            Spacer()
                            Text(String(format: "%.0f%%", it.pct)).font(.inter(.subheadline).monospacedDigit()).foregroundStyle(Palette.muted)
                        }
                        GeometryReader { geo in
                            Capsule().fill(Palette.border.opacity(0.6))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(Palette.accent).frame(width: geo.size.width * it.pct / max(top, 1))
                                }
                        }
                        .frame(height: 6)
                    }
                }
            }
        }
    }

    /// The next round number at or over `v`, for the top of an axis: 1, 2, 2.5 or 5 times a power of ten.
    static func nice(_ v: Double) -> Double {
        guard v > 0 else { return 1 }
        let p = pow(10, floor(log10(v)))
        return ([1, 2, 2.5, 5, 10].first { $0 * p >= v } ?? 10) * p
    }

    /// 1500 → "1.5k", 20000 → "20k".
    static func short(_ v: Double) -> String {
        v >= 1000 ? String(format: v.truncatingRemainder(dividingBy: 1000) == 0 ? "%.0fk" : "%.1fk", v / 1000) : String(format: "%.0f", v)
    }

    private func entries(_ title: String, _ list: [Performance.Social.Entry]) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.nunito(.headline))
                ForEach(list) { e in
                    Button { if let u = URL(string: e.url) { openURL(u) } } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(e.title).font(.inter(.subheadline)).foregroundStyle(Palette.ink).lineLimit(2).multilineTextAlignment(.leading)
                            Text("\(Self.month(e.date, day: true)) · \(e.reach.formatted()) reach · \(e.engagements) eng · \(String(format: "%.1f%%", e.rate))")
                                .font(.inter(.caption).monospacedDigit()).foregroundStyle(Palette.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if e.id != list.last?.id { Divider() }
                }
            }
        }
    }

    // MARK: Posts from Takes

    private func published(_ posts: [Performance.Item]) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Published from Takes").font(.nunito(.headline))
                if posts.isEmpty {
                    Text("No published posts yet.").foregroundStyle(Palette.muted)
                }
                ForEach(posts) { p in
                    NavigationLink(value: model.sessions.first { $0.id == p.session }) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(p.title).font(.inter(.subheadline, .medium)).foregroundStyle(Palette.ink).lineLimit(2)
                                Text("\(p.platform ?? "Post") · \(p.at.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.inter(.caption)).foregroundStyle(Palette.muted)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(p.reach.map { $0.formatted() } ?? "–").font(.subheadline.monospacedDigit().weight(.semibold))
                                Text("\(p.likes ?? 0) ♥ · \(p.comments ?? 0) 💬").font(.inter(.caption).monospacedDigit()).foregroundStyle(Palette.muted)
                            }
                            .foregroundStyle(Palette.ink)
                        }
                    }
                    if p.id != posts.last?.id { Divider() }
                }
            }
        }
    }

    // MARK: Parts

    /// The four headline numbers in one card, two by two with hairlines between (2026-10-03): a
    /// change chip next to the number, a small 14-day line where there is one.
    private func hero(_ h: Performance.Social.Hero) -> some View {
        let month = h.month_complete == true ? Self.month(h.month) : "\(Self.month(h.month)) so far"
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                tile("Followers", h.followers.formatted(),
                     chip: h.followers_gain_8d == 0 ? nil : ("+\(h.followers_gain_8d.formatted())", true),
                     note: "in 8 days", spark: h.followers_spark ?? [], color: Palette.live)
                Divider()
                tile("Impressions a day", h.impr_per_day.formatted(),
                     chip: ("\(h.mom_pct >= 0 ? "+" : "−")\(abs(h.mom_pct))%", h.mom_pct >= 0),
                     note: "\(month) vs \(Self.month(h.prev_month))", spark: h.impr_spark, color: Palette.accent)
            }
            Divider()
            HStack(spacing: 0) {
                tile("Engagement", String(format: "%.1f%%", h.rate), chip: nil,
                     note: "\(h.engagements.formatted()) engagements", spark: [], color: .clear)
                Divider()
                tile("Impressions", Self.short(Double(h.total_impressions)), chip: nil,
                     note: h.peak_month.map { "12 months · best \($0.prefix(3))" } ?? "12 months", spark: [], color: .clear)
            }
        }
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Palette.border))
    }

    private func tile(_ label: String, _ value: String, chip: (String, Bool)?, note: String,
                      spark: [Int], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.inter(.caption, .medium)).foregroundStyle(Palette.muted).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(.nunito(.title2).monospacedDigit()).foregroundStyle(Palette.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
                if let (text, up) = chip {
                    Text(text).font(.inter(.caption2, .semibold).monospacedDigit())
                        .foregroundStyle(up ? Palette.live : Palette.danger)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(up ? Palette.liveSoft : Palette.dangerSoft, in: Capsule())
                        .fixedSize()
                }
            }
            Text(note).font(.inter(.caption2)).foregroundStyle(Palette.faint).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(alignment: .bottom) {
            if spark.count > 1 { Sparkline(values: spark, color: color).frame(height: 26).padding(.bottom, 2).allowsHitTesting(false) }
        }
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Palette.border))
    }

    static func day(_ s: String) -> Date? {
        let key = String(s.prefix(10))
        if let d = Fmt.days[key] { return d }
        let d = Fmt.day.date(from: key)
        Fmt.days[key] = d
        return d
    }

    /// "2026-09" → "Sep". With day: "2026-09-14" → "Sep 14".
    static func month(_ s: String, day: Bool = false) -> String {
        guard let d = (day ? Fmt.day : Fmt.month).date(from: String(s.prefix(day ? 10 : 7))) else { return s }
        return (day ? Fmt.monthDayPOSIX : Fmt.shortMonth).string(from: d)
    }
}

/// Date formatters made once. The charts parse a few hundred dates a draw; a new formatter each
/// time was most of the cost of the tab.
@MainActor
enum Fmt {
    static func make(_ format: String, posix: Bool = true) -> DateFormatter {
        let f = DateFormatter()
        if posix { f.locale = Locale(identifier: "en_US_POSIX") }
        f.dateFormat = format
        return f
    }
    static let day = make("yyyy-MM-dd")
    static let minute = make("yyyy-MM-dd HH:mm")
    static let month = make("yyyy-MM")
    static let shortMonth = make("MMM")
    static let monthDayPOSIX = make("MMM d")
    static let monthDay = make("MMM d", posix: false)
    static let weekday = make("EEE", posix: false)
    /// yyyy-MM-dd → date, parsed once.
    static var days: [String: Date?] = [:]
}

/// A small LinkedIn or X logo, to say where a number comes from.
struct PlatformLogo: View {
    enum Kind { case linkedin, x }
    let kind: Kind
    var size: CGFloat = 16

    var body: some View {
        Text(kind == .linkedin ? "in" : "𝕏")
            .font(.system(size: size * (kind == .linkedin ? 0.66 : 0.62), weight: .heavy))
            .foregroundStyle(.white)
            .offset(y: kind == .linkedin ? size * 0.03 : 0)
            .frame(width: size, height: size)
            .background(kind == .linkedin ? PerformanceView.liBlue : Color.black, in: RoundedRectangle(cornerRadius: size * 0.22))
            .overlay(RoundedRectangle(cornerRadius: size * 0.22).stroke(.white.opacity(kind == .x ? 0.18 : 0), lineWidth: 0.5))
            .accessibilityLabel(kind == .linkedin ? "LinkedIn" : "X")
    }
}

/// A top post as it looks in the LinkedIn feed: the author, the text cut after three lines, the
/// picture or video frame, the reactions line and the impressions of your own post. Tap the
/// text for all of it, tap the card to open it on LinkedIn.
struct FeedCard: View {
    @EnvironmentObject var model: Model
    @Environment(\.openURL) private var openURL
    let entry: Performance.Social.Entry
    let rank: Int
    let profile: Profile?
    @State private var expanded = false

    private var name: String { profile?.name ?? "You" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LinkedInHeader(name: name, headline: profile?.headline ?? "", photo: profile?.photo ?? false, when: Self.ago(entry.date))
                .padding(.horizontal, 12).padding(.top, 12)
            FeedText(text: postText(entry), expanded: $expanded) {
                Text(postText(entry)).font(.system(size: 15)).foregroundStyle(LinkedIn.ink).lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 10)
            if let p = entry.poster, !p.isEmpty { picture(p) }
            reactions.padding(.horizontal, 12).padding(.vertical, 8)
            Rectangle().fill(LinkedIn.line).frame(height: 1).padding(.horizontal, 12)
            LinkedInActions().padding(.horizontal, 4)
            Rectangle().fill(LinkedIn.line).frame(height: 1)
            analytics
        }
        .background(LinkedIn.card)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(LinkedIn.line))
        .overlay(alignment: .topTrailing) {
            Text("#\(rank)").font(.inter(.caption2, .bold).monospacedDigit()).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3).background(Palette.accent, in: Capsule())
                .padding(.top, 10).padding(.trailing, 36)
        }
        .environment(\.colorScheme, .light)
        .contentShape(Rectangle())
        .onTapGesture { if let u = URL(string: entry.url) { openURL(u) } }
    }

    private func postText(_ e: Performance.Social.Entry) -> String {
        let t = (e.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? e.title : t
    }

    private func picture(_ path: String) -> some View {
        ZStack {
            Color.black.opacity(0.05)
            RemoteImage(url: model.api.thumb(path, width: 900)) { $0.resizable().scaledToFit() } placeholder: { ProgressView() }
            if entry.media_type == "video" {
                Image(systemName: "play.fill").font(.system(size: 20)).foregroundStyle(.white)
                    .padding(16).background(.black.opacity(0.55), in: Circle())
            }
        }
        .frame(maxWidth: .infinity).frame(minHeight: 180, maxHeight: 420)
    }

    /// 👍❤️👏 221 · 840 comments · 3 reposts, as the feed writes it.
    private var reactions: some View {
        let likes = entry.likes ?? max(0, entry.engagements - (entry.comments ?? 0) - (entry.reposts ?? 0))
        return HStack(spacing: 4) {
            HStack(spacing: -4) {
                Self.bubble("hand.thumbsup.fill", Color(red: 0.22, green: 0.51, blue: 0.95))
                Self.bubble("heart.fill", Color(red: 0.87, green: 0.33, blue: 0.24))
                Self.bubble("hands.clap.fill", Color(red: 0.42, green: 0.68, blue: 0.29))
            }
            Text(LinkedIn.count(likes)).font(.system(size: 12)).foregroundStyle(LinkedIn.muted)
            Spacer()
            Text([entry.comments.map { "\(LinkedIn.count($0)) comments" }, entry.reposts.flatMap { $0 > 0 ? "\($0) reposts" : nil }]
                .compactMap { $0 }.joined(separator: " • "))
                .font(.system(size: 12)).foregroundStyle(LinkedIn.muted)
        }
    }

    /// The analytics line LinkedIn shows under your own posts.
    private var analytics: some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.bar.fill").font(.system(size: 12))
            Text("\(entry.reach.formatted()) impressions").font(.system(size: 13, weight: .semibold))
            Text("· \(String(format: "%.1f%%", entry.rate))").font(.system(size: 12))
                .accessibilityLabel("\(String(format: "%.1f", entry.rate)) percent engagement")
            Spacer(minLength: 4)
            Text("View analytics").font(.system(size: 13, weight: .semibold)).foregroundStyle(LinkedIn.blue)
        }
        .foregroundStyle(LinkedIn.muted)
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    static func bubble(_ icon: String, _ color: Color) -> some View {
        Image(systemName: icon).font(.system(size: 8)).foregroundStyle(.white)
            .frame(width: 16, height: 16).background(color, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
    }

    /// "2025-12-02" → "10mo", as the feed dates a post.
    static func ago(_ day: String) -> String {
        guard let d = PerformanceView.day(day) else { return day }
        let days = max(0, Calendar.current.dateComponents([.day], from: d, to: Date()).day ?? 0)
        switch days {
        case 0: return "Today"
        case 1..<7: return "\(days)d"
        case 7..<30: return "\(days / 7)w"
        case 30..<365: return "\(days / 30)mo"
        default: return "\(days / 365)yr"
        }
    }
}

/// A small line with a soft fill under it, behind a tile's numbers.
private struct Sparkline: View {
    let values: [Int]
    let color: Color

    var body: some View {
        GeometryReader { g in
            let lo = Double(values.min() ?? 0), hi = Double(values.max() ?? 1)
            let span = max(hi - lo, 1)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: g.size.width * Double(i) / Double(values.count - 1),
                        y: g.size.height * (1 - (Double(v) - lo) / span))
            }
            let line = Path { p in p.addLines(pts) }
            ZStack {
                Path { p in
                    p.addLines(pts)
                    p.addLine(to: CGPoint(x: g.size.width, y: g.size.height))
                    p.addLine(to: CGPoint(x: 0, y: g.size.height))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [color.opacity(0.16), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                line.stroke(color.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
