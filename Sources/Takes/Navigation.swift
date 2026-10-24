import SwiftUI

// Back and forward (2026-10-11), like a browser or the Codex app: ‹ › beside the traffic lights.
// A click on a link, a chat card or a board can land him on another page or tab; ‹ takes him back
// to where he was. A spot is a board, or a session with its tab. Changes that come in one burst
// (a session opens, the board shuts, the tab moves) settle into one spot.

/// One place in the window: a board, or a session and its tab.
struct NavSpot: Equatable {
    var session: URL?
    var tab = ""
    var board: AppModel.Board?
}

/// The places he went, the way a browser keeps them. Going somewhere new drops the forward ones.
struct NavTrail: Equatable {
    private(set) var back: [NavSpot] = []
    private(set) var forward: [NavSpot] = []
    private(set) var here: NavSpot?
    static let most = 50

    mutating func visit(_ s: NavSpot) {
        guard s != here else { return }
        if let h = here { back.append(h); if back.count > Self.most { back.removeFirst() } }
        here = s
        forward = []
    }

    /// The spot before, or nil. `keep` skips spots that are gone (a trashed session).
    mutating func goBack(keep: (NavSpot) -> Bool = { _ in true }) -> NavSpot? {
        while let p = back.popLast() {
            guard keep(p) else { continue }
            if let h = here { forward.append(h) }
            here = p
            return p
        }
        return nil
    }

    mutating func goForward(keep: (NavSpot) -> Bool = { _ in true }) -> NavSpot? {
        while let n = forward.popLast() {
            guard keep(n) else { continue }
            if let h = here { back.append(h) }
            here = n
            return n
        }
        return nil
    }
}

extension AppModel {
    /// Where the window is now.
    var spotNow: NavSpot {
        if let board { return NavSpot(board: board) }
        return NavSpot(session: library.current?.url, tab: UserDefaults.standard.string(forKey: "rightTab") ?? "")
    }

    /// ContentView calls this on every change of board, session or tab. The spot is kept once it
    /// has been still for a moment, so one click makes one step.
    func noteSpot() {
        guard !navRestoring, !isRecording else { return }
        navSettle?.cancel()
        navSettle = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.navSettle = nil
            self.trail.visit(self.spotNow)
        }
    }

    var canGoBack: Bool { !trail.back.isEmpty || navSettle != nil }
    var canGoForward: Bool { !trail.forward.isEmpty && navSettle == nil }

    func goBack() { settleNow(); trail.goBack(keep: exists).map(go) }
    func goForward() { settleNow(); trail.goForward(keep: exists).map(go) }

    /// A change he made a moment ago counts before he goes back from it.
    private func settleNow() {
        guard let t = navSettle else { return }
        t.cancel(); navSettle = nil
        trail.visit(spotNow)
    }

    private func exists(_ s: NavSpot) -> Bool {
        if case .plugin(let id)? = s.board { return Plugins.named(id)?.board != nil }
        if s.board == .performance || s.board == .comments { return Features.socialBoards }  // Public view (2026-10-22)
        return s.session.map { FileManager.default.fileExists(atPath: $0.path) } ?? true
    }

    private func go(_ s: NavSpot) {
        guard !isRecording else { return }
        navRestoring = true
        if let b = s.board {
            board = b
        } else {
            board = nil
            if let u = s.session, library.current?.url != u { library.select(u) }
            if let m = SessionMode(rawValue: s.tab) { SessionMode.set(m) }
        }
        // The views answer the change after this returns (ContentView shuts the board when the
        // session changes): only then may new changes count again.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.navRestoring = false
        }
    }
}

/// The sidebar button and ‹ ›, beside the traffic lights, in Codex's order.
struct NavButtons: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        // The Comments board keeps ⌘[ and ⌘] for its own previous and next post.
        let keys = app.board != .comments
        HStack(spacing: 0) {
            Button { app.toggleSidebars() } label: { icon("sidebar.left") }
                .help("Show or hide the sidebar (⌘B)")
            Button { app.goBack() } label: { icon("chevron.left") }
                .keyboardShortcut(keys ? KeyboardShortcut("[", modifiers: .command) : nil)
                .help("Back (⌘[)")
                .disabled(!app.canGoBack || app.isRecording)
            Button { app.goForward() } label: { icon("chevron.right") }
                .keyboardShortcut(keys ? KeyboardShortcut("]", modifiers: .command) : nil)
                .help("Forward (⌘])")
                .disabled(!app.canGoForward || app.isRecording)
        }
        .buttonStyle(IconButtonStyle())
    }

    private func icon(_ name: String) -> some View {
        // Thin and grey like the traffic-light row in Codex, not bold toolbar icons.
        Image(systemName: name).font(.system(size: 13, weight: .regular)).frame(width: 28, height: 28)
    }
}
