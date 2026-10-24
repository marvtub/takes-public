import SwiftUI

// The list of videos, laid out as the Mac's sidebar (2026-10-04: "look at the desktop app and
// get the design on the mobile app"): the brand and a new video on top, Find a session, each
// project as a section of plain rows with the day on the right, Published folded under it, and
// Performance, Comments and the other pages in the Takes menu. No cards, no floating buttons, no system menus.
// The menu holds only the pages and Settings (2026-10-11: "pretty overwhelming"): no project
// filter (fold a project instead), and Search starts from Find a session.

struct SessionsView: View {
    @EnvironmentObject var model: Model
    @Environment(\.tabBar) private var tab
    @State private var search = ""
    @State private var path: [Session] = []
    @State private var creating = false
    @State private var note: String?
    @State private var appearance = false
    @State private var brandOpen = false
    @State private var showArchived = false
    /// A project's panel (rename, trash) and its cards (2026-10-09).
    @State private var projectMore: String?
    @State private var confirm: Confirm?
    @State private var ask: NameAsk?
    @AppStorage("foldedProjects") private var folded = ""
    @AppStorage("openPublished") private var openPublished = ""
    @AppStorage("newProject") private var lastProject = "Inbox"

    private var shown: [Session] {
        model.sessions.filter { s in
            search.isEmpty || s.title.localizedCaseInsensitiveContains(search) || s.project.localizedCaseInsensitiveContains(search)
        }
    }

    /// Projects in the order of their newest video.
    private var sections: [(String, [Session])] {
        let live = shown.filter { $0.archived != true }
        let groups = Dictionary(grouping: live, by: \.project)
        return groups.map { ($0.key, $0.value.sorted { $0.updated > $1.updated }) }
            .sorted { ($0.1.first?.updated ?? .distantPast) > ($1.1.first?.updated ?? .distantPast) }
    }

    private var archived: [Session] { shown.filter { $0.archived == true }.sorted { $0.updated > $1.updated } }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 8)
                if brandOpen { brandPanel.transition(.opacity.combined(with: .move(edge: .top))) }
                SearchField(prompt: "Find a session or a clip", text: $search)
                    .padding(.horizontal, 12).padding(.bottom, 8)
                if let note {
                    Text(note).font(.inter(.footnote)).foregroundStyle(Palette.warn)
                        .padding(.horizontal, 22).padding(.bottom, 6)
                        .onTapGesture { self.note = nil }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if !search.isEmpty { clipRow }
                        ForEach(sections, id: \.0) { name, items in section(name, items) }
                        if !archived.isEmpty { archivedGroup }
                        if model.sessions.isEmpty && model.connected {
                            Text("No sessions yet. Tap the pencil for a new one.")
                                .font(.inter(.footnote)).foregroundStyle(Palette.faint)
                                .padding(.horizontal, 12).padding(.top, 14)
                        } else if !search.isEmpty && sections.isEmpty {
                            Text("No session matches \u{201C}\(search)\u{201D}.")
                                .font(.inter(.footnote)).foregroundStyle(Palette.faint)
                                .padding(.horizontal, 12).padding(.top, 14)
                        }
                    }
                    .padding(.horizontal, 10).padding(.bottom, 12)
                    .animation(Brand.quick, value: folded)
                    .animation(Brand.quick, value: openPublished)
                }
                .scrollDismissesKeyboard(.immediately)
                foot
            }
            .background(Palette.surface.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .overlay {
                if let p = projectMore {
                    FloatingPanel(open: Binding(get: { projectMore != nil }, set: { if !$0 { projectMore = nil } }), top: 96) {
                        ProjectMore(project: p, open: Binding(get: { projectMore != nil }, set: { if !$0 { projectMore = nil } }),
                                    confirm: $confirm, ask: $ask)
                    }
                }
            }
            .asks(confirm: $confirm, name: $ask)
            .navigationDestination(for: Session.self) { SessionView(session: $0) }
            .sheet(isPresented: $appearance) { AppearanceSheet(forget: { appearance = false; model.unpair() }) { appearance = false } }
            .task(id: model.connected) { if model.connected { await model.loadPlugins() } }
        }
    }

    // MARK: Top

    /// The brand as one control (it opens the panel below), and a new video.
    private var header: some View {
        HStack(spacing: 6) {
            Button { Brand.select(); withAnimation(Brand.spring) { brandOpen.toggle() } } label: {
                HStack(spacing: 9) {
                    // The app icon, blue tile and all, as the Mac's brand menu shows it (2026-10-04).
                    Image("BrandIcon").resizable().interpolation(.high).frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    Text("Takes").font(.nunito(size: 22, relativeTo: .title3)).foregroundStyle(Palette.ink).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.faint)
                        .rotationEffect(.degrees(brandOpen ? 180 : 0))
                    Circle().fill(model.connected ? Palette.live : Palette.faint).frame(width: 7, height: 7)
                        .padding(.leading, 2)
                        .accessibilityLabel(model.connected ? "Connected to the Mac" : "Not connected")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6).frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Takes menu")
            Button { Task { await create() } } label: {
                ZStack {
                    RoundIcon(icon: "square.and.pencil", tint: Palette.muted, size: 44, label: "New video")
                        .opacity(creating ? 0 : 1)
                    if creating { WorkingDots(color: Palette.muted) }
                }
            }
            .buttonStyle(.press).disabled(creating)
        }
    }

    /// The pages (they sat in the foot and took half the screen, 2026-10-09), then Settings: the
    /// look and forgetting the Mac. Only pages, so it reads at a glance (2026-10-11).
    private var brandPanel: some View {
        VStack(alignment: .leading, spacing: 1) {
            pages
            Rectangle().fill(Palette.border).frame(height: 1).padding(.vertical, 6).padding(.horizontal, 12)
            footRow("Settings", icon: "gearshape", hint: "Look, this Mac") { appearance = true }
        }
        .padding(6)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border, lineWidth: 0.5))
        .shadow(color: Palette.shadow, radius: 10, y: 4)
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    /// Typing in Find a session also offers the footage: the Mac's ⌘K with the same words.
    private var clipRow: some View {
        Button { Brand.select(); SearchSeed.shared.query = search; tab?.wrappedValue = "search" } label: {
            HStack(spacing: 11) {
                Image(systemName: "sparkle.magnifyingglass").font(.system(size: 15)).foregroundStyle(Palette.accent).frame(width: 20)
                Text("Search clips for \u{201C}\(search)\u{201D}").font(.inter(.body, .medium)).foregroundStyle(Palette.ink).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.faint)
            }
            .padding(.horizontal, 12).frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPress())
        .accessibilityLabel("Search clips")
    }

    // MARK: Sections

    private func names(_ raw: String) -> Set<String> { Set(raw.split(separator: "\n").map(String.init)) }
    private func toggle(_ raw: inout String, _ name: String) {
        var set = names(raw)
        if set.contains(name) { set.remove(name) } else { set.insert(name) }
        raw = set.sorted().joined(separator: "\n")
    }

    /// A project: its name (a tap folds it), the videos in work, then Published, folded.
    @ViewBuilder
    private func section(_ name: String, _ items: [Session]) -> some View {
        let shut = search.isEmpty && names(folded).contains(name)
        // As the Mac's sidebar: in work first, then scheduled, the next to go out first (2026-10-09).
        let live = items.filter { !$0.published && $0.booked.isEmpty } + items.filter { !$0.published && !$0.booked.isEmpty }.sorted { $0.next < $1.next }
        let done = items.filter(\.published)
        Button { Brand.select(); toggle(&folded, name) } label: {
            HStack(spacing: 6) {
                Text(name).font(.inter(.subheadline, .semibold)).foregroundStyle(Palette.muted).lineLimit(1)
                if shut { Text("\(items.count)").font(.inter(.footnote, .medium)).foregroundStyle(Palette.faint) }
                Spacer()
                // The Mac sidebar's project menu: our own panel.
                Button { Brand.select(); withAnimation(Brand.quick) { projectMore = name } } label: {
                    Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.faint)
                        .frame(width: 36, height: 34).contentShape(Rectangle())
                }
                .buttonStyle(.press)
                .accessibilityLabel("\(name) actions")
            }
            .padding(.horizontal, 12).frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, name == sections.first?.0 ? 2 : 16)
        if !shut {
            ForEach(live) { row($0) }
            if !done.isEmpty {
                let open = !search.isEmpty || names(openPublished).contains(name)
                foldRow(title: "Published", count: done.count, open: open) { toggle(&openPublished, name) }
                if open { ForEach(done) { row($0) } }
            }
        }
    }

    /// Swiped away videos, folded at the very bottom.
    @ViewBuilder
    private var archivedGroup: some View {
        let open = showArchived || !search.isEmpty
        foldRow(title: "Archived", count: archived.count, open: open) { showArchived.toggle() }
            .padding(.top, 16)
        if open { ForEach(archived) { row($0) } }
    }

    /// "› Published 5": a chevron that turns, a quiet name and its count.
    private func foldRow(title: String, count: Int, open: Bool, _ action: @escaping () -> Void) -> some View {
        Button { Brand.select(); action() } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 10)
                Text(title)
                Text("\(count)").foregroundStyle(Palette.faint.opacity(0.7))
                Spacer()
            }
            .font(.inter(.subheadline, .medium)).foregroundStyle(Palette.faint)
            .padding(.horizontal, 12).frame(height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// One line per video, as on the Mac: a dot when there is something to say, the title, and on
    /// the right what Takes is doing, or the day.
    private func row(_ s: Session) -> some View {
        let back = s.archived == true
        return SwipeAway(label: back ? "Unarchive" : "Archive", icon: back ? "tray.and.arrow.up.fill" : "archivebox.fill",
                         tint: back ? Palette.accent : Palette.warn) {
            Task { await model.archive(s.id, !back) }
        } content: {
            NavigationLink(value: s) {
                HStack(spacing: 10) {
                    // The Mac's SessionDot: live, scheduled (a ring), ready or new from Takes (filled).
                    Group {
                        if s.published { Circle().fill(Palette.live) }
                        else if !s.booked.isEmpty { Circle().strokeBorder(Palette.accent, lineWidth: 1.5) }
                        else if s.ready || s.unread || s.notice { Circle().fill(Palette.accent) }
                        else { Color.clear }
                    }
                    .frame(width: 7, height: 7)
                    Text(s.title.isEmpty ? "New video" : s.title)
                        .font(.inter(.callout)).foregroundStyle(s.published ? Palette.muted : Palette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if s.running {
                        WorkingDots(color: Palette.accent)
                    } else if !s.booked.isEmpty, !s.published {
                        HStack(spacing: 4) {
                            ForEach(s.booked, id: \.platform) { PostLogo(platform: $0.platform, size: 13) }
                            Text(s.next == .distantFuture ? "No time" : Plan.short(s.next))
                        }
                        .font(.inter(.footnote)).monospacedDigit().foregroundStyle(Palette.faint)
                    } else {
                        Text(Self.age(s.updated)).font(.inter(.footnote)).monospacedDigit().foregroundStyle(Palette.faint)
                    }
                }
                .padding(.horizontal, 12).frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowPress())
        }
        .accessibilityIdentifier("session-row")
        .accessibilityAction(named: back ? "Unarchive" : "Archive") { Task { await model.archive(s.id, !back) } }
    }

    /// "now", "5m", "3h", "2d", then the date: short, like the Mac's sidebar.
    static func age(_ d: Date) -> String {
        let s = max(0, Date.now.timeIntervalSince(d))
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        if s < 7 * 86_400 { return "\(Int(s / 86_400))d" }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }

    // MARK: Foot

    /// Performance, Comments, the plugins and Styles: the Mac's sidebar foot, inside the Takes menu
    /// so the sessions keep the screen. Search starts from Find a session (2026-10-11).
    @ViewBuilder private var pages: some View {
        // model.publicView: the Mac's Public view redraws this (2026-10-22).
        if Features.socialBoards && !model.publicView {
            footRow("Performance", icon: "chart.bar.xaxis") { tab?.wrappedValue = "performance" }
            footRow("Comments", icon: "text.bubble") { tab?.wrappedValue = "comments" }
        }
        ForEach(model.plugins, id: \.id) { p in footRow(p.title, icon: p.icon) { tab?.wrappedValue = "plugin:" + p.id } }
        footRow("Styles", icon: "square.stack") { tab?.wrappedValue = "styles" }
    }

    /// Update and the waiting changes. Both draw nothing when there is none.
    private var foot: some View {
        VStack(spacing: 1) {
            // Admin only: Ideas' bar, so an idea is one tap away (2026-10-11). Nothing in the public copy.
            // Not in the Mac's Public view (2026-10-22).
            if !model.publicView { PrivatePhone.homeBar { tab?.wrappedValue = $0 } }
            UpdatePill()
            OutboxBar(outbox: model.outbox)
        }
        .padding(.horizontal, 10)
        .background(Palette.surface)
    }

    private func footRow(_ title: String, icon: String, hint: String? = nil, _ action: @escaping () -> Void) -> some View {
        Button { Brand.select(); brandOpen = false; action() } label: {
            HStack(spacing: 11) {
                Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Palette.muted).frame(width: 20)
                Text(title).font(.inter(.body, .medium)).foregroundStyle(Palette.muted)
                Spacer()
                if let hint { Text(hint).font(.inter(.footnote)).foregroundStyle(Palette.faint) }
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.faint)
            }
            .padding(.horizontal, 12).frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPress())
        .accessibilityLabel(title)
    }

    /// A new video is an empty, untitled session that opens on its chat. Claude names it from the
    /// first message (2026-10-03: "just the chat with an agent - keep it stupid simple").
    private func create() async {
        creating = true
        defer { creating = false }
        do {
            let s = try await model.newVideo(project: lastProject)
            model.sessions.removeAll { $0.id == s.id }
            model.sessions.insert(s, at: 0)
            path = [s]
        } catch {
            note = error.localizedDescription
        }
    }
}

/// A sidebar row when pressed: the soft well the Mac shows on hover.
struct RowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(configuration.isPressed ? Palette.ink.opacity(0.06) : .clear))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Swipe a row left to act on it (archive): a coloured strip with the action shows behind it;
/// past the line, letting go acts (2026-10-03). Works in a ScrollView, where swipeActions do not.
struct SwipeAway<Content: View>: View {
    let label: String
    let icon: String
    let tint: Color
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var dx: CGFloat = 0
    @State private var armed = false
    private let line: CGFloat = 110

    var body: some View {
        content()
            .offset(x: dx)
            .background(alignment: .trailing) {
                if dx < 0 {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(armed ? tint : tint.opacity(0.55))
                        .overlay(alignment: .trailing) {
                            Label(label, systemImage: icon).labelStyle(.iconOnly)
                                .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                                .scaleEffect(armed ? 1.15 : 1)
                                .padding(.trailing, 24)
                        }
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onChanged { g in
                        // Sideways only: a vertical drag is the list scrolling.
                        guard abs(g.translation.width) > abs(g.translation.height) * 1.5 || dx != 0 else { return }
                        dx = min(0, g.translation.width)
                        let now = dx < -line
                        if now != armed { armed = now; Brand.select() }
                    }
                    .onEnded { _ in
                        if armed {
                            withAnimation(Brand.spring) { dx = -600 }
                            action()
                        }
                        withAnimation(Brand.spring) { dx = 0; armed = false }
                    }
            )
            .animation(Brand.quick, value: armed)
    }
}

/// The waiting build's changes, as the Mac's What's new: "Area: headline; more" shows the area
/// small above the headline. A tap on the heading folds the list.
struct UpdateChanges: View {
    let changes: [String]
    @Binding var open: Bool

    static func split(_ subject: String) -> (area: String, headline: String) {
        var area = "", rest = Substring(subject)
        if let r = subject.range(of: ": "), subject[..<r.lowerBound].count <= 24 {
            area = String(subject[..<r.lowerBound])
            rest = subject[r.upperBound...]
        }
        var headline = String(rest.split(separator: ";", maxSplits: 1).first ?? rest)
        if let first = headline.first { headline = first.uppercased() + headline.dropFirst() }
        return (area, headline)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeOut(duration: 0.2)) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Text(changes.count == 1 ? "1 change" : "\(changes.count) changes")
                        .font(.inter(.caption, .semibold)).foregroundStyle(Palette.muted)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.faint)
                        .rotationEffect(.degrees(open ? 0 : -90))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(open ? "Hide what's new" : "Show what's new")
            if open {
                ForEach(Array(changes.enumerated()), id: \.offset) { _, c in
                    let p = Self.split(c)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(Palette.accent).frame(width: 5, height: 5)
                        VStack(alignment: .leading, spacing: 1) {
                            if !p.area.isEmpty {
                                Text(p.area.uppercased()).font(.inter(size: 10, .semibold, relativeTo: .caption2))
                                    .tracking(0.5).foregroundStyle(Palette.faint)
                            }
                            Text(p.headline).font(.inter(.footnote)).foregroundStyle(Palette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.leading, 43).padding(.trailing, 12).padding(.bottom, 10)
    }
}

/// "Update" when the Mac has a new build of this app: a sidebar row in the accent, as on the Mac.
/// A tap has the Mac install it; the app ends and opens again on the new build (2026-10-03).
struct UpdatePill: View {
    @EnvironmentObject var model: Model
    /// What's new starts open, as on the Mac (2026-10-11): the row alone said nothing about the build.
    @State private var showChanges = true

    var body: some View {
        if let r = model.update?.renew {
            // The Mac cannot renew the free 7-day profile: say what to do before the app stops.
            HStack(alignment: .firstTextBaseline, spacing: 11) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 15)).frame(width: 20)
                Text(r).font(.inter(.caption, .medium)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.danger)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .accessibilityElement(children: .combine)
        }
        if let u = model.update, u.stamp != nil {
            Button {
                Brand.select()
                Task { await model.installUpdate() }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 11) {
                        Image(systemName: u.error == nil ? "arrow.down.circle.fill" : "exclamationmark.circle.fill")
                            .font(.system(size: 15)).frame(width: 20)
                        Text(model.updating ? "Updating…" : "Update").font(.inter(.body, .semibold))
                        Spacer()
                        if model.updating { WorkingDots(color: Palette.accent) }
                        else if let stamp = u.stamp { Text(stamp).font(.inter(.caption)).foregroundStyle(Palette.faint).lineLimit(1) }
                    }
                    if let e = u.error { Text(e).font(.inter(.caption)).foregroundStyle(Palette.danger).padding(.leading, 31) }
                }
                .foregroundStyle(Palette.accent)
                .padding(.horizontal, 12).frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowPress())
            .disabled(model.updating)
            .accessibilityLabel(model.updating ? "Updating" : "Update the app")
            .transition(.opacity)
            if let changes = u.changes, !changes.isEmpty {
                UpdateChanges(changes: changes, open: $showChanges)
            }
        }
    }
}
