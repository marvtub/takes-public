import SwiftUI

/// Plan's calm first open (2026-10-30), as the Mac's FirstPlan (Plugins/Consistency.swift, picked in
/// design 2026-10-26): the flame and its level badge, one question, big day keys, time and places in
/// one card, a strip of the next two weeks, and one line on what comes next. Change days keeps
/// PlanCommit. Public.
struct PlanFirst: View {
    @EnvironmentObject var model: Model
    var now = Date()
    let done: () -> Void
    @State private var days: Set<String> = PlanWords.suggested
    @State private var time = PlanWords.times[0].1
    @State private var other = false
    @State private var custom = ""
    @State private var platforms: Set<String> = ["linkedin"]
    @State private var saving = false
    @FocusState private var typing: Bool

    private var ok: Bool { !days.isEmpty && !platforms.isEmpty && PlanWords.validTime(time) }
    private var rank: Int { min(days.count, 4) }

    var body: some View {
        VStack(spacing: 20) {
            PlanFlame(rank: rank, size: 88)
            VStack(spacing: 8) {
                Text(PlanWords.levels[rank])
                    .font(.inter(size: 12, .bold, relativeTo: .caption))
                    .foregroundStyle(Self.chipInk(rank))
                    .padding(.horizontal, 12).frame(height: 26)
                    .background(Self.chipFill(rank), in: Capsule())
                Text("When do you want to post?")
                    .font(.nunito(size: 32, heavy: true, relativeTo: .largeTitle)).foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Text(coach).font(.inter(.subheadline)).foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            .animation(Brand.quick, value: days.count)

            HStack(spacing: 5) {
                ForEach(PlanWords.weekdays, id: \.self) { d in dayKey(d) }
            }

            VStack(spacing: 0) {
                row("Time") {
                    HStack(spacing: 3) {
                        ForEach(PlanWords.times, id: \.1) { t in
                            segment(t.0, PlanWords.clock(t.1), on: !other && time == t.1) { other = false; time = t.1 }
                        }
                        if other {
                            TextField("09:41", text: $custom)
                                .font(.inter(.footnote, .semibold)).monospacedDigit().multilineTextAlignment(.center)
                                .keyboardType(.numbersAndPunctuation).focused($typing)
                                .frame(maxWidth: .infinity).frame(height: 44)
                                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.paper).shadow(color: Palette.shadow, radius: 1.5, y: 1))
                                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(!custom.isEmpty && !PlanWords.validTime(custom) ? Palette.warn : .clear, lineWidth: 1.5))
                                .onChange(of: custom) { _, v in if PlanWords.validTime(v) { time = v } }
                                .accessibilityLabel("Any time, 24-hour")
                        } else {
                            segment("Other", "Pick a time", on: false) { other = true; custom = ""; typing = true }
                        }
                    }
                    .padding(3)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Palette.canvas))
                }
                Rectangle().fill(Palette.border).frame(height: 0.5)
                row("Where") {
                    HStack(spacing: 5) {
                        ForEach(PlanWords.platforms, id: \.0) { p in place(p.0, p.1) }
                        Spacer(minLength: 0)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.paper).shadow(color: Palette.shadow, radius: 12, y: 4))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.border, lineWidth: 0.5))

            strip

            VStack(spacing: 10) {
                Button(action: save) {
                    Text("I'm in").font(.inter(size: 16, .bold, relativeTo: .headline))
                        .foregroundStyle(ok ? Color.white : Palette.faint)
                        .padding(.horizontal, 44).frame(height: 52)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ok ? Palette.accent : Palette.well)
                            .shadow(color: ok ? Palette.accent.opacity(0.35) : .clear, radius: 10, y: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.press).disabled(!ok || saving)
                Text("Next you put a video on each day. Takes can do it for you. Change your days any time.")
                    .font(.inter(.footnote)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .animation(Brand.spring, value: other)
    }

    private var coach: String {
        days.isEmpty ? "Tap the days you want a post to go out." : Self.cheer[min(days.count, 4) - 1] + " " + PlanWords.perMonth(days.count)
    }

    /// The Mac's FirstPlan.cheer: CoachWords.forCount without the level name, which the badge says.
    static let cheer = ["A calm start. One good post a week adds up.", "Easy to keep, enough to grow.",
                        "A small buffer will carry you through busy weeks.", "Cheap formats will save you on busy days."]

    /// The Mac's FirstPlan.chipFill and chipInk.
    static func chipFill(_ r: Int) -> Color {
        r == 0 ? Palette.well : r < 3 ? Palette.accentSoft : PlanFlame.hex([0x3B82F6, 0x3B82F6, 0x3B82F6, 0xFF6A1A, 0xFFB800][r]).opacity(0.16)
    }

    static func chipInk(_ r: Int) -> Color {
        switch r {
        case 0: return Palette.muted
        case 1, 2: return Palette.accentInk
        case 3: return Color(light: 0xB4430A, dark: 0xFFA066)
        default: return Color(light: 0x8A5A00, dark: 0xFFD25C)
        }
    }

    /// The Mac's big DayKey: taller, with a glow under the picked ones and a dot under Tue and Thu.
    private func dayKey(_ d: String) -> some View {
        let on = days.contains(d)
        return Button { Brand.select(); withAnimation(Brand.spring) { if on { days.remove(d) } else { days.insert(d) } } } label: {
            VStack(spacing: 6) {
                Text(d.prefix(1).uppercased() + d.dropFirst()).font(.inter(size: 14, .bold, relativeTo: .subheadline))
                Circle().fill(PlanWords.suggested.contains(d) ? (on ? Color.white.opacity(0.85) : Palette.accentInk) : .clear).frame(width: 5, height: 5)
            }
            .foregroundStyle(on ? Color.white : Palette.ink)
            .frame(maxWidth: .infinity).frame(height: 60)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(on ? Palette.accent : Palette.paper)
                .shadow(color: on ? Palette.accent.opacity(0.32) : .clear, radius: 8, y: 6))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(on ? .clear : Palette.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.press)
        .accessibilityLabel(d.capitalized)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func row(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.inter(size: 12, .semibold, relativeTo: .caption)).foregroundStyle(Palette.muted).frame(width: 40, alignment: .leading)
            content()
        }
        .padding(.horizontal, 12).padding(.vertical, 12)
    }

    private func segment(_ title: String, _ detail: String, on: Bool, tap: @escaping () -> Void) -> some View {
        Button { Brand.select(); withAnimation(Brand.quick, tap) } label: {
            VStack(spacing: 1) {
                Text(title).font(.inter(size: 12, .semibold, relativeTo: .footnote))
                Text(detail).font(.inter(size: 10, relativeTo: .caption2)).opacity(0.8)
            }
            .lineLimit(1).minimumScaleFactor(0.8)
            .foregroundStyle(on ? Palette.ink : Palette.muted)
            .frame(maxWidth: .infinity).frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? Palette.paper : .clear)
                .shadow(color: on ? Palette.shadow : .clear, radius: 1.5, y: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.press)
        .accessibilityLabel("\(title) \(detail)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func place(_ id: String, _ name: String) -> some View {
        let on = platforms.contains(id)
        return Button { Brand.select(); withAnimation(Brand.quick) { if on { platforms.remove(id) } else { platforms.insert(id) } } } label: {
            Text(name).font(.inter(size: 12, .semibold, relativeTo: .footnote)).lineLimit(1).fixedSize()
                .foregroundStyle(on ? Palette.accentInk : Palette.muted)
                .padding(.horizontal, 10).frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? Palette.accentSoft : Palette.paper))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? Palette.accent : Palette.border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.press)
        .accessibilityLabel(name)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// The next two weeks from today, the posting days dashed.
    private var strip: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let dates = (0..<14).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
        let posting = dates.filter { days.contains(PlanWords.weekdays[(cal.component(.weekday, from: $0) + 5) % 7]) }
        return VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your next two weeks").font(.inter(size: 12, .semibold, relativeTo: .caption)).foregroundStyle(Palette.muted)
                Spacer()
                Text("\(posting.count) posting day\(posting.count == 1 ? "" : "s") to fill")
                    .font(.inter(size: 12, relativeTo: .caption)).foregroundStyle(Palette.muted).contentTransition(.numericText())
            }
            HStack(spacing: 3) {
                ForEach(dates, id: \.self) { d in
                    let on = posting.contains(d)
                    let isToday = d == today
                    VStack(spacing: 1) {
                        Text(PlanWords.weekdays[(cal.component(.weekday, from: d) + 5) % 7].prefix(1).uppercased())
                            .font(.inter(size: 9, .semibold, relativeTo: .caption2)).opacity(0.75)
                        Text("\(cal.component(.day, from: d))").font(.inter(size: 11, .bold, relativeTo: .caption))
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(on ? Palette.accentInk : isToday ? Palette.ink : Palette.faint)
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Palette.paper : isToday ? Palette.well : Palette.canvas))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(on ? Palette.accent : .clear, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(posting.count) posting days in the next two weeks")
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
                done()
            }
        }
    }
}
