import SwiftUI

// When a post goes out, on the phone (2026-10-09), as the Mac's StatusControl and SchedulePanel
// (Post.swift): Schedule on a draft, a pill with the plan once it has one, and a panel with the
// day, the time and the zone. Drawn in Takes's own style, not the stock date picker. The Mac side
// is /api/schedule in PhoneActions.swift. Public.

/// One post in the posting plan, on a session's row in the list.
struct Planned: Codable, Hashable {
    var platform: String
    var status: String
    var at: Date?
}

/// A platform's mark, as the Mac's PlatformLogo draws it.
struct PostLogo: View {
    let platform: String
    var size: CGFloat = 13

    var body: some View {
        let r = RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
        ZStack {
            switch platform {
            case "linkedin":
                r.fill(PerformanceView.liBlue)
                Text("in").font(.system(size: size * 0.62, weight: .heavy)).foregroundStyle(.white).offset(y: -size * 0.02)
            case "x":
                r.fill(Color.black)
                Text("𝕏").font(.system(size: size * 0.62, weight: .bold)).foregroundStyle(.white)
            case "youtube":
                RoundedRectangle(cornerRadius: size * 0.2, style: .continuous).fill(Color(red: 1, green: 0, blue: 0)).frame(height: size * 0.72)
                Image(systemName: "play.fill").font(.system(size: size * 0.34)).foregroundStyle(.white)
            case "vertical":
                RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                    .strokeBorder(Palette.faint, lineWidth: max(1.2, size * 0.11))
                    .frame(width: size * 0.6, height: size * 0.96)
            default:
                r.fill(Palette.accent)
                Image(systemName: "paperplane.fill").font(.system(size: size * 0.48)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

enum Plan {
    /// "Fri, Oct 10, 9:00 AM PDT": the Mac's PostFile.label.
    static func label(_ d: Date, _ zone: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = zone
        f.dateFormat = "EEE, MMM d, h:mm a zzz"
        return f.string(from: d)
    }

    /// "9:00 AM" today, "Tue 9:00 AM" this week, else "Oct 9": the Mac sidebar's short time.
    static func short(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: .now), to: d).day, days > 0, days < 7 {
            return d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }

    /// The same wall-clock time in another zone: 9:00 in LA becomes 9:00 in Berlin.
    static func moved(_ date: Date, from: TimeZone, to: TimeZone) -> Date {
        var a = Calendar(identifier: .gregorian); a.timeZone = from
        var b = Calendar(identifier: .gregorian); b.timeZone = to
        return b.date(from: a.dateComponents([.year, .month, .day, .hour, .minute], from: date)) ?? date
    }

    /// Yours first, then the usual ones: the Mac's PostFile.zones.
    static func zones(with extra: TimeZone? = nil) -> [TimeZone] {
        let ids = [TimeZone.current.identifier, extra?.identifier].compactMap { $0 } + [
            "America/Los_Angeles", "America/Denver", "America/Chicago", "America/New_York", "America/Sao_Paulo",
            "Europe/London", "Europe/Berlin", "Europe/Istanbul", "Asia/Dubai", "Asia/Kolkata", "Asia/Singapore",
            "Asia/Tokyo", "Australia/Sydney", "UTC"]
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }.compactMap(TimeZone.init(identifier:))
    }

    static func zoneName(_ z: TimeZone) -> String {
        let city = z.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? z.identifier
        return "\(city) (\(z.abbreviation() ?? ""))"
    }

    /// Tomorrow at 9:00 in the zone: a good first guess.
    static func nextMorning(in zone: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: .now)) ?? .now
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }
}

/// Draft: Schedule. Ready, scheduled, posted: a pill with the plan. Either opens the panel.
struct SchedulePill: View {
    let post: PlatformPost
    let open: () -> Void

    private var at: Date? { post.at }
    private var zone: TimeZone { post.tz.flatMap(TimeZone.init(identifier:)) ?? .current }
    private var update: Bool { post.needsUpdate == true }

    var body: some View {
        Button { Brand.select(); open() } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(label).lineLimit(1)
            }
            .font(.inter(.footnote, .semibold))
            .padding(.horizontal, 12).frame(height: 32)
            .foregroundStyle(post.status == "draft" ? Palette.paper : post.status == "posted" ? Palette.live : update ? Palette.warn : Palette.accentInk)
            .background(post.status == "draft" ? Palette.ink : post.status == "posted" ? Palette.liveSoft : Palette.accentSoft, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.press)
        .accessibilityLabel(post.status == "draft" ? "Schedule" : "When it goes out: \(label)")
    }

    private var icon: String {
        if post.status == "draft" { return "calendar" }
        return update ? "exclamationmark.circle" : post.status == "scheduled" ? "checkmark" : post.status == "posted" ? "paperplane" : "clock"
    }

    private var label: String {
        let when = at.map { Plan.label($0, zone) }
        switch post.status {
        case "draft": return "Schedule"
        case "ready": return when ?? "Ready, no time"
        case "scheduled": return update ? "Needs update" : when ?? "Scheduled"
        default: return "Posted" + (when.map { " · " + $0 } ?? "")
        }
    }
}

/// The Mac's SchedulePanel: the day on a month, the time, the zone, and Set time. Ready with no
/// time, Remove the Time and Back to Draft sit under it as quiet words, not a menu.
struct ScheduleSheet: View {
    @EnvironmentObject var model: Model
    let sessionID: String
    let post: PlatformPost
    let close: () -> Void
    @State private var date = Date()
    @State private var zoneID = TimeZone.current.identifier
    @State private var month = Date()
    @State private var busy = false
    @State private var failed: String?

    private var zone: TimeZone { TimeZone(identifier: zoneID) ?? .current }
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = zone; c.firstWeekday = Calendar.current.firstWeekday; return c }
    private var saved: Date? { post.at }
    private var savedZone: TimeZone { post.tz.flatMap(TimeZone.init(identifier:)) ?? .current }
    private var place: String { post.name }

    var body: some View {
        VStack(spacing: 0) {
            SheetBar(title: post.status == "posted" ? "Posted" : "When does it go out?", close: close) {
                Button(busy ? "Saving…" : saved == nil ? "Set time" : "Save") { send(["action": "set", "at": Self.iso(date, zone), "tz": zoneID]) }
                    .buttonStyle(.pill(.ink, small: true)).disabled(busy)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    calendar.arrive(0)
                    time.arrive(1)
                    zones.arrive(2)
                    VStack(alignment: .leading, spacing: 6) {
                        if zone.identifier != TimeZone.current.identifier {
                            Text("That is \(Plan.label(date, .current)) here.").font(.inter(.footnote)).foregroundStyle(Palette.muted)
                        }
                        Text(post.status == "scheduled"
                             ? "It is on \(place) for \(saved.map { Plan.label($0, savedZone) } ?? "a time"). A new time here: ask Takes to move it."
                             : "Then tell Takes \"schedule my posts\". It schedules the post on \(place) for this time and marks it scheduled here.")
                            .font(.inter(.footnote)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                        if let failed { Text(failed).font(.inter(.footnote, .medium)).foregroundStyle(Palette.danger) }
                    }
                    .arrive(3)
                    more.arrive(4)
                }
                .padding(.horizontal, 20).padding(.bottom, 30)
            }
        }
        .background(Palette.paper.ignoresSafeArea())
        .onAppear {
            zoneID = savedZone.identifier
            date = saved ?? Plan.nextMorning(in: savedZone)
            month = date
        }
    }

    // MARK: The month

    private var calendar: some View {
        let days = monthDays
        let title = { () -> String in let f = DateFormatter(); f.timeZone = zone; f.dateFormat = "MMMM yyyy"; return f.string(from: month) }()
        return VStack(spacing: 10) {
            HStack {
                Text(title).font(.nunito(size: 18, relativeTo: .headline)).foregroundStyle(Palette.ink)
                Spacer()
                step("chevron.left", "Previous month") { shiftMonth(-1) }
                step("chevron.right", "Next month") { shiftMonth(1) }
            }
            let symbols = Self.weekdays(cal)
            HStack(spacing: 0) {
                ForEach(Array(symbols.enumerated()), id: \.offset) { _, s in
                    Text(s).font(.inter(.caption2, .semibold)).foregroundStyle(Palette.faint).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, d in
                    if let d { day(d) } else { Color.clear.frame(height: 38) }
                }
            }
        }
    }

    private func day(_ d: Date) -> some View {
        let on = cal.isDate(d, inSameDayAs: date)
        let today = cal.isDate(d, inSameDayAs: .now)
        let past = d < cal.startOfDay(for: .now)
        return Button { Brand.select(); pick(d) } label: {
            Text("\(cal.component(.day, from: d))")
                .font(.inter(.callout, on || today ? .semibold : .regular)).monospacedDigit()
                .foregroundStyle(on ? Palette.paper : today ? Palette.accent : past ? Palette.faint : Palette.ink)
                .frame(width: 38, height: 38)
                .background(on ? Palette.accent : .clear, in: Circle())
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(d.formatted(date: .complete, time: .omitted))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var monthDays: [Date?] {
        guard let start = cal.date(from: cal.dateComponents([.year, .month], from: month)),
              let count = cal.range(of: .day, in: .month, for: start)?.count else { return [] }
        let lead = (cal.component(.weekday, from: start) - cal.firstWeekday + 7) % 7
        return Array(repeating: nil, count: lead) + (0..<count).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    private func shiftMonth(_ n: Int) {
        withAnimation(Brand.quick) { month = cal.date(byAdding: .month, value: n, to: month) ?? month }
    }

    /// Another day, the same time.
    private func pick(_ d: Date) {
        let t = cal.dateComponents([.hour, .minute], from: date)
        date = cal.date(bySettingHour: t.hour ?? 9, minute: t.minute ?? 0, second: 0, of: d) ?? d
    }

    static func weekdays(_ cal: Calendar) -> [String] {
        let s = cal.veryShortStandaloneWeekdaySymbols
        return Array(s[(cal.firstWeekday - 1)...] + s[..<(cal.firstWeekday - 1)])
    }

    // MARK: The time

    private var time: some View {
        let f = { () -> DateFormatter in let f = DateFormatter(); f.timeZone = zone; f.dateFormat = "h:mm a"; return f }()
        return VStack(alignment: .leading, spacing: 8) {
            Text("TIME").font(.inter(.caption, .semibold)).tracking(0.8).foregroundStyle(Palette.muted)
            HStack(spacing: 10) {
                step("minus", "Earlier") { nudge(-15) }
                Text(f.string(from: date)).font(.inter(.title3, .semibold)).monospacedDigit().foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(Palette.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentTransition(.numericText())
                step("plus", "Later") { nudge(15) }
            }
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 6) {
                ForEach([(8, 0), (9, 0), (12, 0), (17, 0)], id: \.0) { h, m in
                    let on = cal.component(.hour, from: date) == h && cal.component(.minute, from: date) == m
                    ToggleChip(title: f.string(from: cal.date(bySettingHour: h, minute: m, second: 0, of: date) ?? date), on: on) {
                        date = cal.date(bySettingHour: h, minute: m, second: 0, of: date) ?? date
                    }
                }
            } }
        }
    }

    private func nudge(_ minutes: Int) {
        withAnimation(Brand.quick) { date = cal.date(byAdding: .minute, value: minutes, to: date) ?? date }
    }

    // MARK: The zone

    private var zones: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TIME ZONE").font(.inter(.caption, .semibold)).tracking(0.8).foregroundStyle(Palette.muted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Plan.zones(with: savedZone), id: \.identifier) { z in
                        ToggleChip(title: Plan.zoneName(z), on: z.identifier == zoneID) {
                            date = Plan.moved(date, from: zone, to: z)
                            zoneID = z.identifier
                        }
                    }
                }
            }
        }
    }

    // MARK: The rest

    @ViewBuilder private var more: some View {
        let ready = post.status == "draft"
        let clear = saved != nil && post.status != "posted"
        let back = post.status != "draft"
        if ready || clear || back {
            VStack(alignment: .leading, spacing: 2) {
                if ready { quiet("Ready, No Time Yet", "clock") { send(["action": "ready"]) } }
                if clear { quiet("Remove the Time", "calendar.badge.minus") { send(["action": "clear"]) } }
                if back { quiet("Back to Draft", "arrow.uturn.backward") { send(["action": "draft"]) } }
            }
            .padding(.top, 4)
            .overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1).offset(y: -8) }
        }
    }

    private func quiet(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button { Brand.select(); action() } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.muted).frame(width: 20)
                Text(title).font(.inter(.callout)).foregroundStyle(Palette.ink)
                Spacer()
            }
            .padding(.horizontal, 6).frame(height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPress())
        .disabled(busy)
        .accessibilityLabel(title)
    }

    private func step(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button { Brand.select(); action() } label: {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                .frame(width: 44, height: 44)
                .background(Palette.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.press)
        .accessibilityLabel(label)
    }

    private func send(_ body: [String: String]) {
        busy = true
        Task {
            defer { busy = false }
            var q = ["id": model.resolve(sessionID)]
            q["platform"] = post.platform
            if let e = await model.tryAct("/api/schedule", q, body) { failed = e; return }
            close()
            // The list's dot and time follow at once.
            await model.refresh()
        }
    }

    static func iso(_ d: Date, _ zone: TimeZone) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = zone
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
}
