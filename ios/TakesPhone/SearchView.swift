import SwiftUI

// The Mac's ⌘K as a phone screen (2026-10-09): sessions, projects and boards by name, then clips,
// stills and words by what they show or say, with the same chips. The Mac searches
// (Sources/Takes/PhoneSearch.swift, MediaSearch). Public.

struct Hit: Codable, Hashable, Identifiable {
    var kind: String
    var path: String
    var start: Double
    var text: String?
    var title: String?
    var session: String?
    var board: String?
    var id: String { kind + ":" + (title ?? "") + path + "#\(start)" }
}

struct SearchResult: Codable, Hashable {
    var hits: [Hit]
    var status: String
}

struct SearchView: View {
    @EnvironmentObject var model: Model
    @Environment(\.tabBar) private var tab
    @State private var query = ""
    @State private var filter = "all"
    @State private var project: String?
    @State private var result: SearchResult?
    @State private var picking = false
    @State private var path: [Session] = []
    @State private var showing: Hit?
    @FocusState private var focused: Bool

    private static let filters = [("all", "All"), ("takes", "Takes"), ("edits", "Edits"), ("broll", "B-roll"), ("stills", "Stills"), ("scripts", "Scripts")]
    private var projects: [String] { model.projects.isEmpty ? Array(Set(model.sessions.map(\.project))).sorted() : model.projects }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(alignment: .leading, spacing: 0) {
                ScreenHeader(title: "") { EmptyView() } trailing: { EmptyView() }
                field.padding(.horizontal, 16).arrive(0)
                chips.padding(.top, 10).arrive(1)
                Rectangle().fill(Palette.border).frame(height: 1).padding(.top, 10)
                results
            }
            .background(Palette.surface.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Session.self) { SessionView(session: $0) }
            .overlay {
                if picking {
                    FloatingPanel(open: $picking, alignment: .topTrailing, top: 150) {
                        PanelChoice(title: "All projects", checked: project == nil) { project = nil; picking = false }
                        PanelDivider()
                        ForEach(projects, id: \.self) { p in PanelChoice(title: p, checked: project == p) { project = p; picking = false } }
                    }
                }
            }
            .fullScreenCover(item: $showing) { h in
                Viewer(file: Bubble.guess(h.path), sessionID: h.session ?? "", onDone: { showing = nil })
            }
            .task { await model.loadProjects() }
            .onAppear { focused = true }
        }
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
            TextField("Sessions, boards and footage: \"hands typing\"", text: $query)
                .font(.inter(.callout)).focused($focused).submitLabel(.search)
                .accessibilityIdentifier("search-field")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.faint) }
                    .buttonStyle(.press).accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 14).frame(height: 46)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(focused ? Palette.accent.opacity(0.5) : Palette.border, lineWidth: focused ? 1.5 : 1))
    }

    /// All · Takes · Edits · B-roll · Stills · Scripts, and the project on the right, as the Mac's.
    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Self.filters, id: \.0) { f in ToggleChip(title: f.1, on: filter == f.0) { filter = f.0 } }
                Button { Brand.select(); withAnimation(Brand.quick) { picking.toggle() } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder").font(.system(size: 11))
                        Text(project ?? "All projects").lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                    .font(.inter(.footnote, .medium)).foregroundStyle(project == nil ? Palette.muted : Palette.ink)
                    .padding(.horizontal, 12).frame(height: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.press)
                .accessibilityLabel("Project: \(project ?? "All projects")")
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder private var results: some View {
        let hits = result?.hits ?? []
        ScrollView {
            if hits.isEmpty {
                Text(query.isEmpty ? (result?.status ?? "") : result == nil ? " " : filter != "all" || project != nil
                     ? "Nothing found here. Pick All or All projects to search everything." : "Nothing found.")
                    .font(.inter(.subheadline)).foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(Array(hits.enumerated()), id: \.element.id) { i, h in
                        Button { open(h) } label: { HitRow(hit: h) }
                            .buttonStyle(RowPress())
                            .arrive(min(i, 8))
                    }
                }
                .padding(8)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .task(id: "\(query)|\(filter)|\(project ?? "")") {
            // As on the Mac: wait a moment while typing, then ask once.
            try? await Task.sleep(for: .milliseconds(query.isEmpty ? 0 : 220))
            guard !Task.isCancelled else { return }
            var q = ["q": query, "filter": filter]
            if let project { q["project"] = project }
            guard let d = try? await model.act("/api/search", q, nil, method: "GET"),
                  let r = try? API.decoder.decode(SearchResult.self, from: d), !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.28)) { result = r }
        }
    }

    private func open(_ h: Hit) {
        Brand.select()
        if let b = h.board { tab?.wrappedValue = b; return }
        if h.kind == "project" { project = h.title; return }
        if h.kind == "session", let id = h.session {
            path = [model.sessions.first { $0.id == id } ?? Session(id: id, title: h.title ?? "", project: String(id.split(separator: "/").first ?? ""),
                                                                    created: .now, updated: .now, takes: 0, running: false, unread: false, notice: false, published: false)]
            return
        }
        if h.kind == "script", let id = h.session, let s = model.sessions.first(where: { $0.id == id }) { path = [s]; return }
        showing = h
    }
}

/// A named row (session, project, board): one line. A file: its frame, what matched, and where.
private struct HitRow: View {
    @EnvironmentObject var model: Model
    let hit: Hit

    var body: some View {
        if let title = hit.title {
            HStack(spacing: 10) {
                Image(systemName: hit.kind == "board" ? "square.grid.2x2" : hit.kind == "project" ? "folder" : "video")
                    .font(.system(size: 13)).foregroundStyle(Palette.muted).frame(width: 22)
                Text(title).font(.inter(.callout, .medium)).foregroundStyle(Palette.ink).lineLimit(1)
                if let t = hit.text { Text(t).font(.inter(.footnote)).foregroundStyle(Palette.faint).lineLimit(1) }
                Spacer()
            }
            .padding(.horizontal, 10).frame(height: 44)
            .contentShape(Rectangle())
        } else {
            HStack(spacing: 12) {
                ZStack {
                    Palette.well
                    if hit.kind != "script" {
                        RemoteImage(url: model.api.thumb(hit.path, width: 240)) { $0.resizable().scaledToFill() } placeholder: { Palette.well }
                    } else {
                        Image(systemName: "doc.text").foregroundStyle(Palette.muted)
                    }
                }
                .frame(width: 84, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(hit.text.map { "“\($0)”" } ?? (hit.path as NSString).lastPathComponent)
                        .font(.inter(.subheadline, .medium)).foregroundStyle(Palette.ink).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(Self.kind(hit.kind))
                        if hit.start > 0 { Text(BoardView.clock(hit.start)).monospacedDigit() }
                        if let s = hit.session { Text(s.split(separator: "/").last.map(String.init) ?? s).lineLimit(1) }
                    }
                    .font(.inter(.footnote)).foregroundStyle(Palette.faint)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
    }

    static func kind(_ k: String) -> String {
        ["video": "Clip", "image": "Still", "speech": "Said", "script": "Script", "name": "Name"][k] ?? k.capitalized
    }
}
