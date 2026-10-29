import SwiftUI

/// Plan on the phone (2026-10-25), as the Mac's board (Plugins/Consistency.swift, PlanWeeks.swift,
/// PlanGame.swift): the mascot in its flame and the next posting day, videos per week with the
/// streak chain and the crown, the plan's weeks with their video cards, Change days, and the Plan
/// chat. The Mac sends the board ready to draw (Plugins/PlanPhone.swift there); each button calls the
/// Mac's own and writes the same line in the Plan chat. A day's + and a card's Move to stand in for
/// the Mac's hover + and drag. Public.

struct PlanData: Decodable, Equatable {
    struct Plan: Decodable, Equatable {
        var days: [String]
        var time: String
        var platforms: [String]
        var weeks: Int
    }

    struct Week: Decodable, Equatable {
        var label: String
        var now: Bool
        var posted: Int
        var scheduled: Int
        var planned: Int
        var words: String
        var link: String?
        var total: Int { posted + scheduled + planned }
    }

    struct Crown: Decodable, Equatable {
        var week: Int
        var title: String
        var label: String
        var reach: String
        var platform: String
        var session: String
    }

    struct Card: Decodable, Hashable, Identifiable {
        var id: String
        var title: String
        var poster: String?
        var status: String?
        var statusText: String?
        var step: Int?
        var late: Bool
    }

    struct Day: Decodable, Hashable, Identifiable {
        var day: String
        var label: String
        var today: Bool
        var planned: Bool
        var cards: [Card]
        var filled: String?
        var open: Bool
        var id: String { day }
    }

    var plan: Plan?
    var subtitle: String
    var headline: String
    var rank: Int
    var level: String
    var perMonth: String
    var goal: Int
    var weeks: [Week]
    var note: String
    var streak: Int
    var streakWords: String
    var restWords: String
    var crown: Crown?
    var stripTitle: String
    var summary: String
    var days: [Day]
    var weekCount: Int
    var minWeeks: Int
    var maxWeeks: Int
    var ready: [String]
}

struct PlanChoice: Decodable, Equatable, Identifiable, Hashable {
    var id: String
    var title: String
    var project: String
    var done: Bool
}

enum PlanWords {
    static let chatID = "board:consistency"
    static let weekdays = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    static let suggested: Set<String> = ["tue", "thu"]
    /// As the Mac's (PostingPlan.times): odd minutes look like a person posted.
    static let times = [("Morning", "08:02"), ("Lunch", "12:07"), ("Evening", "17:33")]
    static let platforms = [("linkedin", "LinkedIn"), ("x", "X"), ("youtube", "YouTube"), ("vertical", "Vertical")]
    /// The Mac's FireLevel names.
    static let levels = ["Pick a day to start", "Warming up", "The sweet spot", "On fire", "Super Takes"]
    static let stepNames = ["Idea", "Script", "Record", "Edit", "Post"]

    static func clock(_ hhmm: String) -> String {
        let p = hhmm.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2 else { return hhmm }
        return String(format: "%d:%02d %@", p[0] % 12 == 0 ? 12 : p[0] % 12, p[1], p[0] < 12 ? "AM" : "PM")
    }

    static func validTime(_ s: String) -> Bool {
        let p = s.split(separator: ":", omittingEmptySubsequences: false)
        guard p.count == 2, p[1].count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return false }
        return (0..<24).contains(h) && (0..<60).contains(m)
    }

    static func perMonth(_ n: Int) -> String {
        n == 0 ? "Pick at least one day." : "That's \(n) post\(n == 1 ? "" : "s") a week, about \(Int((Double(n) * 4.3).rounded())) a month."
    }

    /// The Mac's gold for the streak and the crown, the same in light and dark.
    static let gold = Color(red: 0.95, green: 0.66, blue: 0.18)
}

struct PlanScreen: View {
    @EnvironmentObject var model: Model
    @State private var data: PlanData?
    @State private var failed: String?
    @State private var editing = false
    @State private var talking = false
    @State private var adding: PlanData.Day?
    /// The card whose menu is open, and its day.
    @State private var card: CardPick?
    private struct CardPick { let card: PlanData.Card; let day: PlanData.Day }
    @State private var opened: Session?

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Plan", subtitle: data?.subtitle ?? "Show up on the days you choose") { EmptyView() } trailing: {
                if data?.plan != nil && !editing {
                    Button("Change days") { withAnimation(Brand.spring) { editing = true } }.buttonStyle(.pill(.quiet, small: true))
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let d = data {
                        if d.plan == nil || editing {
                            PlanCommit(start: d.plan, first: d.plan == nil) { done in
                                if done { Task { await load() } }
                                withAnimation(Brand.spring) { editing = false }
                            }
                            .arrive(0)
                        } else {
                            top(d).arrive(0)
                            PlanChart(data: d) { open($0) }.planCard().arrive(1)
                            PlanStrip(data: d, add: { adding = $0 }, open: { open($0.id) }, more: { c, day in withAnimation(Brand.quick) { card = CardPick(card: c, day: day) } },
                                      weeks: { n in act(["action": "weeks", "n": n]) })
                                .planCard().arrive(2)
                            if !d.ready.isEmpty { ready(d).planCard().arrive(3) }
                        }
                    } else if let failed {
                        MascotEmpty(title: "Can't load your plan", message: failed, mood: .sorry).padding(.top, 30)
                    }
                }
                .padding(16).padding(.bottom, 90)
            }
            .refreshable { await load() }
        }
        .overlay(alignment: .bottom) {
            if !editing {
                Button { Brand.tap(.medium); talking = true } label: {
                    Label("Plan chat", systemImage: "bubble.left.and.bubble.right.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.pill(.primary, wide: true))
                .padding(.horizontal, 16).padding(.bottom, 12)
            }
        }
        .overlay {
            if let pick = card, let d = data {
                let c = pick.card, day = pick.day
                CardOverlay(close: { withAnimation(Brand.quick) { card = nil } }) {
                    PlanCardMenu(card: c, day: day, data: d) { action in
                        withAnimation(Brand.quick) { card = nil }
                        switch action {
                        case .open: open(c.id)
                        case .move(let to, let before): place(c.id, on: to, before: before)
                        case .remove: act(["action": "remove", "id": c.id])
                        }
                    }
                }
            }
        }
        .background(Palette.surface.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .bottom) { Toast(text: $model.toast) }
        .animation(Brand.quick, value: model.toast)
        .navigationDestination(isPresented: $talking) {
            BoardChatView(id: PlanWords.chatID, title: "Plan", empty: "Ask Takes to plan your videos, fill the next posting day, or change your days.",
                          from: "Plan")
        }
        .navigationDestination(item: $adding) { day in
            PlanPicker(day: day) { id in
                adding = nil
                place(id, on: day.day, before: nil)
            }
        }
        .navigationDestination(item: $opened) { SessionView(session: $0) }
        .task(id: talking) {
            // The chat and the Mac change the plan too: look again every few seconds while it shows.
            while !Task.isCancelled && !talking {
                await load()
                try? await Task.sleep(for: .seconds(6))
            }
        }
    }

    private func top(_ d: PlanData) -> some View {
        HStack(spacing: 14) {
            PlanFlame(rank: d.rank, size: 46)
                .onTapGesture { withAnimation(Brand.spring) { editing = true } }
                .accessibilityLabel("\(d.level). Change your days")
                .accessibilityAddTraits(.isButton)
            VStack(alignment: .leading, spacing: 4) {
                Text(d.headline).font(.nunito(size: 21, relativeTo: .title3)).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(d.level). \(d.perMonth)").font(.inter(.footnote)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func ready(_ d: PlanData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ready, waiting for a slot").font(.inter(.subheadline, .bold)).foregroundStyle(Palette.ink)
            ForEach(d.ready, id: \.self) { title in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Palette.live)
                    Text(title).font(.inter(.subheadline)).foregroundStyle(Palette.ink).lineLimit(1)
                }
            }
            Text("Ask Takes in the chat to put one in your next open slot.").font(.inter(.caption)).foregroundStyle(Palette.faint)
        }
    }

    private func open(_ id: String) {
        if let s = model.sessions.first(where: { $0.id == id }) { opened = s } else { model.toast = "That video is not on this phone yet. Pull the list to refresh." }
    }

    private func place(_ id: String, on day: String, before: String?) {
        var body: [String: Any] = ["action": "place", "id": id, "day": day]
        if let before { body["before"] = before }
        act(body)
    }

    private func act(_ body: [String: Any]) {
        Brand.tap()
        Task {
            if let e = await model.tryAct("/api/plan", [:], body) { model.toast = e }
            await load()
        }
    }

    private func load() async {
        do {
            let d = try await model.act("/api/plan", [:], nil, method: "GET")
            let p = try API.decoder.decode(PlanData.self, from: d)
            if p != data { withAnimation(Brand.spring) { data = p } }
            failed = nil
        } catch {
            if data == nil { failed = error.localizedDescription }
        }
    }
}

private extension View {
    /// The Mac's .card: paper, a hairline, 12 pt corners.
    func planCard() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border, lineWidth: 0.5))
    }
}

// MARK: - The flame

/// The mascot in its flame (the Mac's FireMascot): none with no days, gold "Super Takes" at four or more.
struct PlanFlame: View {
    let rank: Int
    var size: CGFloat = 60
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var flick = false

    private var r: Int { min(max(rank, 0), 4) }
    private var outer: Color { Self.hex([0x3B82F6, 0x3B82F6, 0x3B82F6, 0xFF6A1A, 0xFFB800][r]) }
    private var inner: Color { Self.hex([0x8DB4FF, 0x8DB4FF, 0x9FE3FF, 0xFFC14D, 0xFFF3A8][r]) }
    private var opacity: Double { [0, 0.45, 0.8, 1, 1][r] }
    private var scale: CGFloat { [0.6, 0.7, 0.85, 1, 1.22][r] }

    static func hex(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var body: some View {
        let box = size * 1.5
        ZStack(alignment: .top) {
            ZStack {
                PlanFlameShape(outer: true).fill(outer).opacity(0.6)
                    .scaleEffect(x: 1, y: flick ? 1.09 : 1, anchor: .bottom)
                PlanFlameShape(outer: false).fill(inner).opacity(0.85)
                    .scaleEffect(x: 1, y: flick ? 1 : 1.07, anchor: .bottom)
            }
            .frame(width: box, height: box * 0.84)
            .scaleEffect(scale, anchor: .bottom)
            .opacity(opacity)
            Image("Mascot").resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: size)
                .saturation(r == 0 ? 0 : 1)
                .opacity(r == 0 ? 0.6 : 1)
                .colorMultiply(r == 4 ? Self.hex(0xFFE38A) : .white)
                .shadow(color: r >= 3 ? outer.opacity(0.6) : Palette.shadow, radius: r >= 3 ? 10 : 5, y: 3)
                .offset(y: box * 0.84 - size * 0.9)
        }
        .frame(width: box, height: box * 0.9, alignment: .top)
        .animation(Brand.spring, value: r)
        .onAppear {
            guard !reduce else { return }
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { flick = true }
        }
    }
}

/// The Mac's FlameShape: a spiky aura in a 200 × 168 box, its base on the bottom edge.
struct PlanFlameShape: Shape {
    let outer: Bool

    func path(in rect: CGRect) -> Path {
        let outerPts: [CGFloat] = [100, 8, 108, 40, 128, 34, 136, 12, 140, 46, 160, 52, 174, 34, 170, 70, 186, 84, 194, 98,
                                   176, 108, 182, 140, 160, 168]
        let outerBack: [CGFloat] = [40, 168, 18, 140, 24, 108, 6, 98, 14, 84, 30, 70, 26, 34, 40, 52, 60, 46, 64, 12, 72, 34, 92, 40, 100, 8]
        let innerPts: [CGFloat] = [100, 40, 106, 62, 120, 58, 126, 42, 130, 66, 146, 72, 156, 60, 154, 88, 166, 100, 170, 110,
                                   158, 118, 162, 142, 148, 168]
        let innerBack: [CGFloat] = [52, 168, 38, 142, 42, 118, 30, 110, 34, 100, 46, 88, 44, 60, 54, 72, 70, 66, 74, 42, 80, 58, 94, 62, 100, 40]
        let (fwd, back) = outer ? (outerPts, outerBack) : (innerPts, innerBack)
        let p = { (x: CGFloat, y: CGFloat) in CGPoint(x: rect.minX + x / 200 * rect.width, y: rect.minY + y / 168 * rect.height) }
        var path = Path()
        path.move(to: p(fwd[0], fwd[1]))
        for i in stride(from: 2, to: fwd.count, by: 6) {
            path.addCurve(to: p(fwd[i + 4], fwd[i + 5]), control1: p(fwd[i], fwd[i + 1]), control2: p(fwd[i + 2], fwd[i + 3]))
        }
        path.addLine(to: p(back[0], back[1]))
        for i in stride(from: 2, to: back.count, by: 6) {
            path.addCurve(to: p(back[i + 4], back[i + 5]), control1: p(back[i], back[i + 1]), control2: p(back[i + 2], back[i + 3]))
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Videos per week

/// The Mac's PlanWeeks: posted (mint), scheduled (blue) and planned (dashed) against the goal, the
/// streak pill, the gold chain and the crown. A tap on a week says its numbers (the Mac's hover).
struct PlanChart: View {
    let data: PlanData
    let open: (String) -> Void
    @State private var picked: Int?
    @State private var restShown = false

    private let plotHeight: CGFloat = 110

    var body: some View {
        let top = max(data.goal, data.weeks.map(\.total).max() ?? 0, 1)
        let showChain = data.streak > 0 || data.weeks.contains { $0.link != nil }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Videos per week").font(.inter(.subheadline, .bold)).foregroundStyle(Palette.ink)
                if data.streak > 0 {
                    Button { Brand.select(); withAnimation(Brand.quick) { restShown.toggle() } } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "flame.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(PlanWords.gold)
                            Text("\(data.streak) week\(data.streak == 1 ? "" : "s") in a row").font(.inter(.footnote, .semibold))
                                .foregroundStyle(Palette.ink).monospacedDigit()
                        }
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(PlanWords.gold.opacity(0.13)))
                    }
                    .buttonStyle(.press)
                    .accessibilityHint(data.restWords)
                }
                Spacer(minLength: 0)
            }
            Text(restShown ? data.restWords : data.streakWords).font(.inter(.caption)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
            GeometryReader { g in
                let n = max(data.weeks.count, 1)
                let col = g.size.width / CGFloat(n)
                let bar = min(col * 0.55, 26)
                let unit = (plotHeight - (data.crown == nil ? 0 : 18)) / CGFloat(top)
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Palette.border).frame(width: g.size.width, height: 1).offset(y: plotHeight)
                    ForEach(Array(data.weeks.enumerated()), id: \.offset) { i, wk in
                        column(wk, i, bar: bar, unit: unit)
                            .frame(width: col, height: plotHeight)
                            .offset(x: CGFloat(i) * col)
                    }
                    if data.goal > 0 {
                        Path { p in
                            let y = plotHeight - unit * CGFloat(data.goal)
                            p.move(to: CGPoint(x: 0, y: y))
                            p.addLine(to: CGPoint(x: g.size.width, y: y))
                        }
                        .stroke(Palette.muted, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: plotHeight)
            if showChain { chain }
            labels
            HStack(alignment: .top) {
                Text(data.note).font(.inter(.caption)).foregroundStyle(Palette.faint)
                Spacer(minLength: 8)
                if let i = picked, data.weeks.indices.contains(i) {
                    Text(data.weeks[i].words).font(.inter(.caption, .medium)).foregroundStyle(Palette.ink).multilineTextAlignment(.trailing)
                        .transition(.opacity)
                }
            }
            if picked == nil { legends.transition(.opacity) }
        }
    }

    private func column(_ wk: PlanData.Week, _ i: Int, bar: CGFloat, unit: CGFloat) -> some View {
        VStack(spacing: 2) {
            Spacer(minLength: 0)
            if wk.planned > 0 {
                RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
                    .frame(width: bar, height: max(unit * CGFloat(wk.planned) - 2, 3))
            }
            if wk.scheduled > 0 {
                RoundedRectangle(cornerRadius: 4).fill(Palette.accent).frame(width: bar, height: max(unit * CGFloat(wk.scheduled) - 2, 3))
            }
            if wk.posted > 0 {
                RoundedRectangle(cornerRadius: 4).fill(Palette.live).frame(width: bar, height: max(unit * CGFloat(wk.posted) - 2, 3))
            }
        }
        .overlay(alignment: .bottom) {
            if let c = data.crown, c.week == i {
                Button { open(c.session) } label: {
                    Image(systemName: "crown.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(PlanWords.gold)
                        .frame(width: 28, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.press)
                .offset(y: -(unit * CGFloat(wk.total) + 2))
                .accessibilityLabel("\(c.label): \(c.title), \(c.reach) impressions on \(c.platform)")
            }
        }
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(picked == i ? Palette.well : wk.now ? Palette.well.opacity(0.5) : .clear)
            .padding(.horizontal, 1))
        .contentShape(Rectangle())
        .onTapGesture { Brand.select(); withAnimation(Brand.quick) { picked = picked == i ? nil : i } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(wk.words)
    }

    /// The chain: a flame under each week at the goal, a moon on a rest week, a dashed circle on
    /// this week while it is open. Gold links join them.
    private var chain: some View {
        GeometryReader { geo in
            let weeks = data.weeks
            let col = geo.size.width / CGFloat(max(weeks.count, 1))
            ZStack(alignment: .topLeading) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { i, wk in
                    if i + 1 < weeks.count, let l = wk.link, l != "open", let next = weeks[i + 1].link {
                        Capsule().fill(PlanWords.gold.opacity(next == "open" ? 0.18 : 0.45))
                            .frame(width: col, height: 3)
                            .offset(x: col * (CGFloat(i) + 0.5), y: 8.5)
                    }
                }
                ForEach(Array(weeks.enumerated()), id: \.offset) { i, wk in
                    Group {
                        switch wk.link {
                        case "counted":
                            Image(systemName: "flame.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(PlanWords.gold)
                                .frame(width: 18, height: 18).background(Circle().fill(Palette.paper))
                        case "rest":
                            Image(systemName: "moon.zzz.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.muted)
                                .frame(width: 18, height: 18).background(Circle().fill(Palette.paper))
                        case "open":
                            Circle().strokeBorder(PlanWords.gold.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                                .frame(width: 13, height: 13).background(Circle().fill(Palette.paper))
                        default:
                            EmptyView()
                        }
                    }
                    .position(x: col * (CGFloat(i) + 0.5), y: 10)
                }
            }
        }
        .frame(height: 20)
        .accessibilityHidden(true)
    }

    /// Every week's date; with many weeks every other one, so they stay readable. This week always.
    private var labels: some View {
        let every = data.weeks.count > 10 ? 2 : 1
        return HStack(spacing: 0) {
            ForEach(Array(data.weeks.enumerated()), id: \.offset) { i, wk in
                Text(wk.now ? "Now" : (i % every == 0 ? wk.label : ""))
                    .font(.inter(size: 9, wk.now ? .semibold : .regular))
                    .foregroundStyle(wk.now ? Palette.ink : Palette.faint)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private var legends: some View {
        HStack(spacing: 12) {
            legend("Posted") { RoundedRectangle(cornerRadius: 2).fill(Palette.live) }
            legend("Scheduled") { RoundedRectangle(cornerRadius: 2).fill(Palette.accent) }
            legend("Planned") { RoundedRectangle(cornerRadius: 2).strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 1.2, dash: [3, 2])) }
            if data.goal > 0 { legend("Goal \(data.goal)") { Rectangle().fill(Palette.muted).frame(height: 1.5).frame(maxHeight: .infinity) } }
        }
    }

    private func legend<S: View>(_ text: String, @ViewBuilder swatch: () -> S) -> some View {
        HStack(spacing: 4) {
            swatch().frame(width: 11, height: 9)
            Text(text).font(.inter(.caption2)).foregroundStyle(Palette.muted).lineLimit(1)
        }
    }
}

// MARK: - The weeks

/// The plan's weeks (the Mac's SlotStrip). The Mac lays a week out as seven columns; the phone has
/// a row per day: its name, its video cards, and its slot (open, dashed; or the post that fills it).
struct PlanStrip: View {
    let data: PlanData
    var editable = true
    var add: (PlanData.Day) -> Void = { _ in }
    var open: (PlanData.Card) -> Void = { _ in }
    var more: (PlanData.Card, PlanData.Day) -> Void = { _, _ in }
    var weeks: (Int) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(data.stripTitle).font(.inter(.subheadline, .bold)).foregroundStyle(Palette.ink)
                Text(data.summary).font(.inter(.caption)).foregroundStyle(Palette.faint)
            }
            ForEach(0..<max((data.days.count + 6) / 7, 0), id: \.self) { w in
                VStack(spacing: 0) {
                    ForEach(Array(data.days.dropFirst(w * 7).prefix(7))) { d in
                        PlanDayRow(day: d, editable: editable, add: { add(d) }, open: open, more: { more($0, d) })
                        if d.id != data.days.dropFirst(w * 7).prefix(7).last?.id { Rectangle().fill(Palette.border.opacity(0.6)).frame(height: 0.5) }
                    }
                }
                .padding(.horizontal, 8)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if editable {
                HStack(spacing: 8) {
                    if data.weekCount < data.maxWeeks {
                        Button { weeks(data.weekCount + 1) } label: { Label("Add a week", systemImage: "plus") }.buttonStyle(.pill(.soft, small: true))
                    }
                    if data.weekCount > data.minWeeks {
                        Button { weeks(data.weekCount - 1) } label: { Label("Show less", systemImage: "minus") }.buttonStyle(.pill(.quiet, small: true))
                    }
                    Spacer(minLength: 0)
                }
                if data.days.allSatisfy({ $0.cards.isEmpty }) {
                    Text("Tap + on a day to add a video, or ask Takes in the chat.").font(.inter(.caption)).foregroundStyle(Palette.faint)
                }
            }
        }
    }
}

struct PlanDayRow: View {
    let day: PlanData.Day
    var editable = true
    let add: () -> Void
    let open: (PlanData.Card) -> Void
    let more: (PlanData.Card) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(day.label).font(.inter(.footnote, day.today ? .bold : .medium))
                .foregroundStyle(day.planned ? Palette.ink : Palette.faint)
                .frame(width: 50, alignment: .leading)
                .padding(.top, 9)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(day.cards) { c in PlanCardRow(card: c, open: { open(c) }, more: editable ? { more(c) } : nil) }
                if let f = day.filled {
                    Text(f).font(.inter(.footnote, .medium)).foregroundStyle(Palette.live).lineLimit(2)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                        .background(Palette.liveSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                } else if day.open {
                    Text("Open").font(.inter(.footnote, .medium)).foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.border, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, day.cards.isEmpty && day.filled == nil && !day.open ? 0 : 6)
            if editable {
                Button(action: add) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.accentInk)
                        .frame(width: 24, height: 24).background(Circle().fill(Palette.accentSoft))
                        .frame(width: 36, height: 36).contentShape(Rectangle())
                }
                .buttonStyle(.press)
                .accessibilityLabel("Add a video to \(day.label)")
            }
        }
        .frame(minHeight: 36)
    }
}

/// A planned video (the Mac's PlanCard): its picture, title, and its post or step dots. A tap opens
/// it; the dots button moves it or takes it off the plan (the Mac's drag and right-click).
struct PlanCardRow: View {
    @EnvironmentObject var model: Model
    let card: PlanData.Card
    let open: () -> Void
    var more: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Palette.well)
                if let p = card.poster {
                    RemoteImage(url: model.api.thumb(p, width: 240)) { $0.resizable().scaledToFill() } placeholder: { Palette.well }
                } else {
                    Image(systemName: "film").font(.system(size: 12)).foregroundStyle(Palette.faint)
                }
            }
            .frame(width: 64, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(card.title).font(.inter(.footnote, .semibold)).foregroundStyle(Palette.ink).lineLimit(2)
                switch card.status {
                case "posted":
                    Label(card.statusText ?? "Posted", systemImage: "checkmark.circle.fill").font(.inter(.caption2, .semibold)).foregroundStyle(Palette.live)
                case "scheduled":
                    Label(card.statusText ?? "Scheduled", systemImage: "clock").font(.inter(.caption2, .medium)).foregroundStyle(Palette.accentInk)
                default:
                    HStack(spacing: 6) {
                        if let s = card.step { PlanStepDots(step: s) }
                        if card.late { Text("planned earlier").font(.inter(.caption2)).foregroundStyle(Palette.faint) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let more {
                Button(action: more) {
                    Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.muted)
                        .frame(width: 32, height: 36).contentShape(Rectangle())
                }
                .buttonStyle(.press)
                .accessibilityLabel("Move or take off \(card.title)")
            }
        }
        .padding(6)
        .background(card.status == "posted" ? Palette.liveSoft : Palette.paper, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.border, lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onTapGesture { Brand.select(); open() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.title)
    }
}

/// Five dots: Idea, Script, Record, Edit, Post (the Mac's StepDots).
struct PlanStepDots: View {
    let step: Int
    var size: CGFloat = 5

    var body: some View {
        HStack(spacing: size * 0.6) {
            ForEach(0..<5, id: \.self) { i in
                Capsule().fill(i <= step ? (step >= 4 ? Palette.live : Palette.accent) : Palette.border)
                    .frame(width: i == step ? size * 2.2 : size, height: size)
            }
        }
        .accessibilityLabel("Done: " + PlanWords.stepNames.prefix(step + 1).joined(separator: ", "))
    }
}

/// A card's menu: open it, move it to another day or up on its day, or take it off the plan.
struct PlanCardMenu: View {
    enum Action { case open, move(String, String?), remove }
    let card: PlanData.Card
    let day: PlanData.Day
    let data: PlanData
    let done: (Action) -> Void
    @State private var moving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(card.title).font(.nunito(size: 19, relativeTo: .headline)).foregroundStyle(Palette.ink).lineLimit(2)
                .padding(.horizontal, 10).padding(.bottom, 6)
            PanelRow(icon: "arrow.up.forward.square", title: "Open") { done(.open) }
            if let i = day.cards.firstIndex(where: { $0.id == card.id }), i > 0 {
                PanelRow(icon: "arrow.up", title: "Move up on \(day.label)") { done(.move(day.day, day.cards[i - 1].id)) }
            }
            PanelGroup(icon: "calendar", title: "Move to", open: $moving) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(data.days.filter { $0.day != day.day }) { d in
                            PanelChoice(title: d.label + (d.planned ? " · posting day" : "")) { done(.move(d.day, nil)) }
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
            PanelDivider()
            PanelRow(icon: "calendar.badge.minus", title: "Take off the plan", danger: true) { done(.remove) }
        }
    }
}

/// A day's +: find a video and tap it to put it on the day (the Mac's PlanPicker).
struct PlanPicker: View {
    @EnvironmentObject var model: Model
    let day: PlanData.Day
    let pick: (String) -> Void
    @State private var query = ""
    @State private var list: [PlanChoice]?

    var body: some View {
        let words = query.lowercased().split(separator: " ")
        let shown = (list ?? []).filter { c in words.allSatisfy { (c.title + " " + c.project).lowercased().contains($0) } }
        let planned = Set(day.cards.map(\.id))
        VStack(spacing: 0) {
            TopBar(title: "Add to \(day.label)", subtitle: day.planned ? "A posting day" : nil) { EmptyView() }
            SearchField(prompt: "Find a video", text: $query).padding(.horizontal, 16).padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if let list, shown.isEmpty {
                        Text(list.isEmpty ? "No sessions yet." : "No video matches.").font(.inter(.footnote)).foregroundStyle(Palette.faint).padding(16)
                    }
                    ForEach(shown.prefix(200)) { c in
                        Button { Brand.select(); pick(c.id) } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.title).font(.inter(.callout, .medium)).foregroundStyle(Palette.ink).lineLimit(1)
                                    Text(c.project + (c.done ? " · done" : "")).font(.inter(.caption)).foregroundStyle(Palette.faint).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if planned.contains(c.id) { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.accent) }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(RowPress())
                        .accessibilityLabel(c.title)
                    }
                }
            }
        }
        .background(Palette.surface.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            guard let d = try? await model.act("/api/plan", ["choices": "1"], nil, method: "GET") else { list = []; return }
            list = (try? API.decoder.decode([PlanChoice].self, from: d)) ?? []
        }
    }
}

// MARK: - Change days

/// Your days and time, in a few taps (the Mac's CommitCard): day keys with Tue and Thu suggested, the
/// time, where you post, and the next two weeks as they would look before you save.
struct PlanCommit: View {
    @EnvironmentObject var model: Model
    let first: Bool
    let done: (Bool) -> Void
    @State private var days: Set<String>
    @State private var time: String
    @State private var custom: String
    @State private var platforms: Set<String>
    @State private var preview: PlanData?
    @State private var saving = false

    init(start: PlanData.Plan?, first: Bool, done: @escaping (Bool) -> Void) {
        self.first = first
        self.done = done
        let t = start?.time ?? PlanWords.times[0].1
        _days = State(initialValue: Set(start?.days ?? Array(PlanWords.suggested)))
        _time = State(initialValue: t)
        _custom = State(initialValue: PlanWords.times.contains { $0.1 == t } ? "" : t)
        _platforms = State(initialValue: Set(start?.platforms ?? ["linkedin"]))
    }

    private var ok: Bool { !days.isEmpty && !platforms.isEmpty && PlanWords.validTime(time) }
    private var rank: Int { min(days.count, 4) }
    private var key: String { PlanWords.weekdays.filter(days.contains).joined(separator: ",") + "|" + time + "|" + platforms.sorted().joined(separator: ",") }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                PlanFlame(rank: rank, size: 50)
                VStack(alignment: .leading, spacing: 4) {
                    Text(first ? "When do you want to show up?" : PlanWords.levels[rank]).font(.nunito(size: 22, relativeTo: .title2)).foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(first ? "\(PlanWords.levels[rank]). \(PlanWords.perMonth(days.count))" : PlanWords.perMonth(days.count))
                        .font(.inter(.footnote)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                }
                .animation(Brand.quick, value: days.count)
            }
            VStack(alignment: .leading, spacing: 8) {
                label("Days", "Tap a day to turn it on or off. A dot marks a suggested day.")
                HStack(spacing: 5) {
                    ForEach(PlanWords.weekdays, id: \.self) { d in
                        let on = days.contains(d)
                        Button { Brand.select(); withAnimation(Brand.spring) { if on { days.remove(d) } else { days.insert(d) } } } label: {
                            VStack(spacing: 4) {
                                Text(d.prefix(1).uppercased() + d.dropFirst()).font(.inter(.footnote, .semibold))
                                Circle().fill(PlanWords.suggested.contains(d) ? (on ? Color.white.opacity(0.85) : Palette.accentInk) : .clear).frame(width: 4, height: 4)
                            }
                            .foregroundStyle(on ? Color.white : Palette.ink)
                            .frame(maxWidth: .infinity).frame(height: 50)
                            .background(on ? Palette.accent : Palette.paper, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(on ? .clear : Palette.border))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.press)
                        .accessibilityLabel(d.capitalized)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                label("Time", nil)
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        ForEach(PlanWords.times, id: \.1) { t in
                            let on = time == t.1 && custom.isEmpty
                            Button { Brand.select(); withAnimation(Brand.quick) { time = t.1; custom = "" } } label: {
                                VStack(spacing: 1) {
                                    Text(t.0).font(.inter(.footnote, .semibold))
                                    Text(PlanWords.clock(t.1)).font(.inter(.caption2)).opacity(0.75)
                                }
                                .foregroundStyle(on ? Palette.accentInk : Palette.muted)
                                .frame(maxWidth: .infinity).frame(height: 44)
                                .background(on ? Palette.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.press)
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                    TextField("Other, 09:41", text: $custom)
                        .font(.inter(.footnote)).monospacedDigit().multilineTextAlignment(.center)
                        .keyboardType(.numbersAndPunctuation)
                        .frame(height: 40)
                        .background(custom.isEmpty ? .clear : Palette.accentSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(!custom.isEmpty && !PlanWords.validTime(custom) ? Palette.warn : .clear, lineWidth: 1.5))
                        .onChange(of: custom) { _, v in if PlanWords.validTime(v) { time = v } else if v.isEmpty { time = PlanWords.times[0].1 } }
                }
                .padding(4)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Palette.border, lineWidth: 0.5))
                Text("In your Mac's time zone. Odd minutes look like a person posted.").font(.inter(.caption)).foregroundStyle(Palette.faint)
            }
            if let preview, !preview.days.isEmpty {
                PlanStrip(data: preview, editable: false).planCard().transition(.opacity)
            }
            VStack(alignment: .leading, spacing: 8) {
                label("Where", nil)
                FlowChips(items: PlanWords.platforms.map(\.0), title: { p in PlanWords.platforms.first { $0.0 == p }?.1 ?? p },
                          on: { platforms.contains($0) }) { p in
                    if platforms.contains(p) { platforms.remove(p) } else { platforms.insert(p) }
                }
                Text("A post on any of these fills the day's slot.").font(.inter(.caption)).foregroundStyle(Palette.faint)
            }
            HStack(spacing: 10) {
                if !first { Button("Cancel") { done(false) }.buttonStyle(.pill(.quiet, wide: true)) }
                Button(first ? "I'm in" : "Save") { save() }.buttonStyle(.pill(.primary, wide: true)).disabled(!ok || saving)
            }
        }
        .task(id: key) {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, !days.isEmpty else { return }
            let q = ["days": PlanWords.weekdays.filter(days.contains).joined(separator: ","), "time": time,
                     "platforms": platforms.sorted().joined(separator: ",")]
            guard let d = try? await model.act("/api/plan", q, nil, method: "GET"),
                  let p = try? API.decoder.decode(PlanData.self, from: d), !Task.isCancelled else { return }
            withAnimation(Brand.quick) { preview = p }
        }
    }

    private func label(_ title: String, _ hint: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.inter(.caption2, .semibold)).tracking(0.6).foregroundStyle(Palette.faint)
            if let hint { Text(hint).font(.inter(.caption)).foregroundStyle(Palette.faint) }
        }
    }

    private func save() {
        saving = true
        Brand.tap(.medium)
        Task {
            let body: [String: Any] = ["action": "save", "days": PlanWords.weekdays.filter(days.contains), "time": time, "platforms": platforms.sorted()]
            if let e = await model.tryAct("/api/plan", [:], body) {
                model.toast = e
                saving = false
            } else {
                done(true)
            }
        }
    }
}

/// Toggle chips in a row: the four places fit on one line.
private struct FlowChips: View {
    let items: [String]
    let title: (String) -> String
    let on: (String) -> Bool
    let tap: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.self) { i in ToggleChip(title: title(i), on: on(i)) { tap(i) } }
            Spacer(minLength: 0)
        }
    }
}
