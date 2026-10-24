import AppKit
import SwiftUI

// The Takes menu kit (2026-10-11): one menu for the whole app, in place of the stock macOS menus.
// Design board: https://claude.ai/artifact/YUNwytSXFvdBuM2JuUF4BZ ("One menu kit for the whole app").
//
//   TakesMenuButton { label } content: { MenuButton(…) … }   a click menu (was Menu { } label: { })
//   .takesMenu(isPresented: $open) { … }                     a menu under any view
//   .takesContextMenu { … }                                  a right-click menu (was .contextMenu)
//   .takesPopover(isPresented: $open) { any view }           a panel (was .popover), no arrow
//   TakesSwitch(selection:, options:)                        two to four choices (was .segmented)
//   .sheet { TakesConfirm(…) }                               a confirm card (was .alert / NSAlert)
//
// Rows: paper panel, radius 12, rows 30 high (radius 7, Inter 13, 15 px icon), groups open in place,
// red danger rows last, an accent check for the picked row. More than 8 rows get type-to-find.
// Keys: ↑ ↓, → ← open and close a group, Return, Esc, letters jump (or find, in a long menu).
// Right-click inside text stays the system menu: it has spelling, Look Up and Services.

// MARK: - Content

/// One row of a menu. Build them with `MenuButton`, `MenuGroup`, `MenuLabel`, `MenuDivider`, `MenuView`.
struct MenuItem: Identifiable {
    enum Kind { case button, group, label, divider, view }
    var id: String
    var kind: Kind
    var title = ""
    var icon: String?
    /// Faint text on the right: a shortcut, a count, a local time.
    var detail: String?
    var checked = false
    var enabled = true
    var danger = false
    /// The menu stays open after the click: a check that switches on and off in place.
    var keepsOpen = false
    var action: (() -> Void)?
    var children: [MenuItem] = []
    var view: AnyView?

    var selectable: Bool { (kind == .button || kind == .group) && enabled }
}

protocol MenuContent { var items: [MenuItem] { get } }

@resultBuilder enum MenuBuilder {
    static func buildExpression(_ c: some MenuContent) -> [MenuItem] { c.items }
    static func buildExpression(_ c: [MenuItem]) -> [MenuItem] { c }
    static func buildBlock(_ parts: [MenuItem]...) -> [MenuItem] { parts.flatMap { $0 } }
    static func buildOptional(_ c: [MenuItem]?) -> [MenuItem] { c ?? [] }
    static func buildEither(first c: [MenuItem]) -> [MenuItem] { c }
    static func buildEither(second c: [MenuItem]) -> [MenuItem] { c }
    static func buildArray(_ c: [[MenuItem]]) -> [MenuItem] { c.flatMap { $0 } }
    static func buildLimitedAvailability(_ c: [MenuItem]) -> [MenuItem] { c }
}

/// A row that does something. `danger` rows are red and go last, after a divider.
struct MenuButton: MenuContent {
    var item: MenuItem
    init(_ title: String, icon: String? = nil, detail: String? = nil, checked: Bool = false,
         enabled: Bool = true, danger: Bool = false, keepsOpen: Bool = false, action: @escaping () -> Void) {
        item = MenuItem(id: "b:" + title, kind: .button, title: title, icon: icon, detail: detail, checked: checked,
                        enabled: enabled, danger: danger, keepsOpen: keepsOpen, action: action)
    }
    var items: [MenuItem] { [item] }
}

/// A row whose rows open right under it, in place (no side submenu).
struct MenuGroup: MenuContent {
    var item: MenuItem
    init(_ title: String, icon: String? = nil, detail: String? = nil, enabled: Bool = true,
         @MenuBuilder _ content: () -> [MenuItem]) {
        let kids = content()
        item = MenuItem(id: "g:" + title, kind: .group, title: title, icon: icon, detail: detail,
                        enabled: enabled && !kids.isEmpty, children: kids.map { var k = $0; k.id = "g:\(title)/" + k.id; return k })
    }
    var items: [MenuItem] { [item] }
}

/// A quiet section name over a few rows: "Camera", "Microphone".
struct MenuLabel: MenuContent {
    let title: String
    init(_ title: String) { self.title = title }
    var items: [MenuItem] { [MenuItem(id: "l:" + title, kind: .label, title: title)] }
}

struct MenuDivider: MenuContent {
    var items: [MenuItem] { [MenuItem(id: "d:" + UUID().uuidString, kind: .divider)] }
}

/// Any view as a row: a switch, theme dots, a footnote. It is not part of the key order.
struct MenuView: MenuContent {
    let id: String
    let view: AnyView
    init<V: View>(_ id: String, @ViewBuilder _ view: () -> V) {
        self.id = id
        self.view = AnyView(view())
    }
    var items: [MenuItem] { [MenuItem(id: "v:" + id, kind: .view, view: view)] }
}

/// Rows with the same title get unique ids (two "Rename" rows in one menu are fine).
private func uniqued(_ items: [MenuItem]) -> [MenuItem] {
    var seen: [String: Int] = [:]
    return items.map { item in
        var i = item
        let n = seen[i.id, default: 0]
        seen[i.id] = n + 1
        if n > 0 { i.id += "#\(n)" }
        i.children = uniqued(i.children)
        return i
    }
}

// MARK: - State

/// What the open menu shows: highlight, open groups, the find text. Keys drive it from the panel.
@Observable @MainActor
final class MenuState {
    var highlight: String?
    var open: Set<String> = []
    var query = ""
    var searchable = false
    /// Set by the panel: closes the menu, then runs the row (a move or a trash changes the view under it).
    var finish: (MenuItem) -> Void = { _ in }

    /// The rows on screen, in order: open groups' rows follow their group; a query shows matches only.
    func visible(_ items: [MenuItem]) -> [(item: MenuItem, depth: Int)] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var out: [(MenuItem, Int)] = []
        if !q.isEmpty {
            func walk(_ list: [MenuItem], _ depth: Int) {
                for i in list {
                    if i.kind == .group {
                        let kids = i.children.filter { $0.kind == .button && $0.title.lowercased().contains(q) }
                        if i.title.lowercased().contains(q) || !kids.isEmpty {
                            out.append((i, depth))
                            for k in (kids.isEmpty ? i.children.filter { $0.kind == .button } : kids) { out.append((k, depth + 1)) }
                        }
                    } else if i.kind == .button, i.title.lowercased().contains(q) {
                        out.append((i, depth))
                    }
                }
            }
            walk(items, 0)
            return out
        }
        func walk(_ list: [MenuItem], _ depth: Int) {
            for i in list {
                out.append((i, depth))
                if i.kind == .group, open.contains(i.id) { walk(i.children, depth + 1) }
            }
        }
        walk(items, 0)
        // A divider never starts or ends a menu, and two never meet.
        var trimmed: [(MenuItem, Int)] = []
        for r in out {
            if r.0.kind == .divider, trimmed.isEmpty || trimmed.last?.0.kind == .divider { continue }
            trimmed.append(r)
        }
        while trimmed.last?.0.kind == .divider { trimmed.removeLast() }
        return trimmed
    }

    func move(_ by: Int, in items: [MenuItem]) {
        let rows = visible(items).map(\.item).filter(\.selectable)
        guard !rows.isEmpty else { return }
        guard let h = highlight, let at = rows.firstIndex(where: { $0.id == h }) else {
            highlight = (by > 0 ? rows.first : rows.last)?.id
            return
        }
        highlight = rows[(at + by + rows.count) % rows.count].id
    }

    func activate(_ item: MenuItem) {
        guard item.enabled else { return }
        if item.kind == .group {
            withAnimation(Theme.motion) {
                if open.contains(item.id) { open.remove(item.id) } else { open.insert(item.id) }
            }
            return
        }
        if item.keepsOpen { item.action?() } else { finish(item) }
    }

    /// → opens the group under the highlight, ← closes it (or the group the row sits in).
    func side(_ openIt: Bool, in items: [MenuItem]) {
        let rows = visible(items)
        guard let h = highlight, let at = rows.firstIndex(where: { $0.item.id == h }) else { return }
        let row = rows[at]
        withAnimation(Theme.motion) {
            if row.item.kind == .group {
                if openIt { open.insert(h) } else { open.remove(h) }
            } else if !openIt, row.depth > 0,
                      let parent = rows[..<at].last(where: { $0.depth == row.depth - 1 && $0.item.kind == .group }) {
                open.remove(parent.item.id)
                highlight = parent.item.id
            }
        }
    }

    /// The keys a menu answers, for the floating panel and for a menu drawn inside a panel.
    /// True when the key was used. Esc and ⌘ keys are the caller's.
    func key(_ e: NSEvent, in items: [MenuItem]) -> Bool {
        guard e.modifierFlags.intersection([.command, .control]).isEmpty else { return false }
        switch e.keyCode {
        case 125: move(1, in: items)
        case 126: move(-1, in: items)
        case 124: side(true, in: items)
        case 123: side(false, in: items)
        case 36, 76:
            guard let h = highlight, let row = visible(items).first(where: { $0.item.id == h }) else { return false }
            activate(row.item)
        case 51:
            guard searchable, !query.isEmpty else { return false }
            query.removeLast(); highlight = nil; move(1, in: items)
        default:
            guard let ch = e.charactersIgnoringModifiers, !ch.isEmpty,
                  ch.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(.punctuationCharacters).union(.whitespaces).contains($0) })
            else { return false }
            if searchable { query += ch; highlight = nil; move(1, in: items) } else { jump(ch, in: items) }
        }
        return true
    }

    /// Long menus (more than 8 rows) get type-to-find.
    static func wantsFind(_ items: [MenuItem]) -> Bool {
        items.reduce(0) { $0 + ($1.kind == .button ? 1 : $1.kind == .group ? 1 + $1.children.count : 0) } > 8
    }

    /// A typed letter jumps to the next row that starts with it.
    func jump(_ ch: String, in items: [MenuItem]) {
        let rows = visible(items).map(\.item).filter(\.selectable)
        let start = rows.firstIndex { $0.id == highlight }.map { $0 + 1 } ?? 0
        let order = Array(rows[start...]) + Array(rows[..<start])
        if let hit = order.first(where: { $0.title.lowercased().hasPrefix(ch.lowercased()) }) { highlight = hit.id }
    }
}

// MARK: - The menu view

/// The panel of rows. `content` is read in body, so a check that changes redraws the menu.
struct TakesMenuList: View {
    let content: () -> [MenuItem]
    @Bindable var state: MenuState
    var width: CGFloat? = nil

    var body: some View {
        let items = uniqued(content())
        let rows = state.visible(items)
        VStack(alignment: .leading, spacing: 1) {
            if state.searchable { MenuFind(query: state.query) }
            ForEach(rows, id: \.item.id) { row in
                MenuRow(item: row.item, depth: row.depth, state: state)
            }
            if state.searchable && rows.isEmpty {
                Text("Nothing called “\(state.query)”").font(Theme.sans(12.5)).foregroundStyle(Theme.faint)
                    .padding(.horizontal, 8).frame(height: 30)
            }
        }
        .padding(6)
        .frame(minWidth: width ?? 220, maxWidth: width ?? 300, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .menuChrome()
        .animation(Theme.motion, value: state.open)
    }
}

/// The find field at the top of a long menu. Typing goes here while the menu is open.
private struct MenuFind: View {
    let query: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
            if query.isEmpty {
                Text("Type to find").font(Theme.sans(12.5)).foregroundStyle(Theme.faint)
            } else {
                Text(query).font(Theme.sans(12.5)).foregroundStyle(Theme.ink)
                    + Text("|").font(Theme.sans(12.5)).foregroundStyle(Theme.accent)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).frame(height: 28)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.border))
        .padding(.horizontal, 2).padding(.top, 2).padding(.bottom, 6)
    }
}

private struct MenuRow: View {
    let item: MenuItem
    let depth: Int
    @Bindable var state: MenuState

    var body: some View {
        switch item.kind {
        case .divider:
            Rule().padding(.horizontal, 6).padding(.vertical, 5)
        case .label:
            Text(item.title).font(Theme.sans(11, .medium)).foregroundStyle(Theme.faint)
                .padding(.horizontal, 8).padding(.top, 7).padding(.bottom, 4)
        case .view:
            item.view
        case .button, .group:
            let lit = state.highlight == item.id && item.enabled
            let child = depth > 0
            HStack(spacing: 10) {
                if item.kind == .group {
                    Image(systemName: "chevron.right").font(.system(size: 9.5, weight: .bold))
                        .rotationEffect(.degrees(state.open.contains(item.id) || !state.query.isEmpty ? 90 : 0))
                        .foregroundStyle(Theme.muted).frame(width: 15)
                } else if let icon = item.icon {
                    Image(systemName: icon).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(item.danger ? Theme.danger : Theme.muted).frame(width: 15)
                }
                Text(item.title).font(Theme.sans(child ? 12.5 : 13))
                    .foregroundStyle(item.danger ? Theme.danger : Theme.ink)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 12)
                if let d = item.detail {
                    Text(d).font(Theme.sans(11.5)).foregroundStyle(Theme.faint).kerning(0.4).lineLimit(1)
                }
                if item.checked {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent)
                }
            }
            .padding(.leading, child ? 8 + 25 * CGFloat(depth) : 8).padding(.trailing, 8)
            .frame(height: child ? 27 : 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(lit ? Theme.ink.opacity(0.06) : .clear))
            .contentShape(Rectangle())
            .opacity(item.enabled ? 1 : 0.4)
            .onHover { if $0 { state.highlight = item.id } else if state.highlight == item.id { state.highlight = nil } }
            .onTapGesture { state.activate(item) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
        }
    }
}

extension View {
    /// The look every Takes menu and panel shares: paper, a hairline, radius 12.
    func menuChrome(radius: CGFloat = 12) -> some View {
        self.background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.paper))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.border))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - The floating panel

/// The one window every menu and panel opens in. Borderless, no arrow, the system's soft shadow
/// around our shape. A menu never takes the keys from the window under it: a monitor reads them,
/// as a real menu does. A panel with a text field becomes key when the field is clicked.
@MainActor
final class MenuPanel {
    static let shared = MenuPanel()

    enum Place {
        /// Under (or over, if no room) a view's frame on screen.
        case below(NSRect)
        /// At the pointer, as a right-click menu opens.
        case at(NSPoint)
        /// Beside a view's frame: the panel opens to its right (or left, if no room).
        case beside(NSRect)
    }

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private var panel: Panel?
    private var monitors: [Any] = []
    private var onClose: (() -> Void)?
    private var state: MenuState?
    private var items: (() -> [MenuItem])?
    private var place: Place = .at(.zero)
    private var upward = false
    private(set) var token = UUID()

    var isOpen: Bool { panel?.isVisible == true }

    /// A menu of rows.
    func show(menu content: @escaping () -> [MenuItem], at place: Place, width: CGFloat? = nil,
              app: AppModel?, onClose: (() -> Void)? = nil) {
        let st = MenuState()
        st.searchable = MenuState.wantsFind(uniqued(content()))
        st.finish = { [weak self] item in
            self?.close()
            if let a = item.action { DispatchQueue.main.async { a() } }
        }
        state = st
        items = content
        present(AnyView(TakesMenuList(content: content, state: st, width: width)), at: place, app: app, menu: true, onClose: onClose)
    }

    /// Any view in the panel chrome (the old popovers).
    func show(panel view: AnyView, at place: Place, app: AppModel?, onClose: (() -> Void)? = nil) {
        state = nil
        items = nil
        present(view, at: place, app: app, menu: false, onClose: onClose)
    }

    func close() {
        guard let p = panel else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        let done = onClose
        onClose = nil
        state = nil
        items = nil
        panel = nil
        token = UUID()
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.12
            p.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                p.parent?.removeChildWindow(p)
                p.orderOut(nil)
            }
        })
        done?()
    }

    private func present(_ view: AnyView, at place: Place, app: AppModel?, menu: Bool, onClose: (() -> Void)?) {
        if panel != nil { close() }
        self.place = place
        self.onClose = onClose
        let p = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        // From the screen pill Takes is not the active app: the menu must stay up all the same.
        p.hidesOnDeactivate = NSApp.isActive
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        p.becomesKeyOnlyIfNeeded = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        var root = AnyView(view.onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] s in
            MainActor.assumeIsolated { self?.fit(s) }
        })
        if let app { root = AnyView(root.environment(app)) }
        let host = NSHostingView(rootView: root)
        host.sizingOptions = [.intrinsicContentSize]
        p.contentView = host
        let size = host.fittingSize
        panel = p
        let frame = self.frame(for: size)
        p.setFrame(frame.offsetBy(dx: 0, dy: upward ? -4 : 4), display: false)
        p.alphaValue = 0
        // Only on a window you can see: the pill puts the Takes window away, and a menu on it
        // went away with it (2026-10-14: the pill's camera and mic menus never showed).
        if let parent = NSApp.keyWindow ?? NSApp.mainWindow, parent !== p, parent.isVisible { parent.addChildWindow(p, ordered: .above) }
        p.orderFront(nil)
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.18
            c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
            p.animator().setFrame(frame, display: true)
        }
        // A panel (a form, a list with a field) takes the keys as a popover did; a menu never does.
        if !menu { p.makeKey() }
        watch(menu: menu)
    }

    /// The content grew or shrank (a group opened): keep the edge that faces the anchor.
    private func fit(_ size: CGSize) {
        guard let p = panel, size.width > 0, size.height > 0 else { return }
        let f = p.frame
        guard abs(f.width - size.width) > 0.5 || abs(f.height - size.height) > 0.5 else { return }
        let top = f.maxY
        var n = NSRect(x: f.minX, y: upward ? f.minY : top - size.height, width: size.width, height: size.height)
        if let screen = p.screen?.visibleFrame, n.minY < screen.minY { n.origin.y = screen.minY + 4 }
        p.setFrame(n, display: true)
        p.invalidateShadow()
    }

    private func frame(for size: CGSize) -> NSRect {
        let screen = (NSScreen.screens.first { s in
            switch place {
            case .below(let r), .beside(let r): s.frame.contains(NSPoint(x: r.midX, y: r.midY))
            case .at(let pt): s.frame.contains(pt)
            }
        } ?? NSScreen.main)?.visibleFrame ?? .zero
        var x: CGFloat, y: CGFloat
        switch place {
        case .below(let r):
            x = r.minX
            y = r.minY - 4 - size.height
            upward = y < screen.minY
            if upward { y = r.maxY + 4 }
        case .at(let pt):
            x = pt.x + 2
            y = pt.y - size.height
            upward = y < screen.minY
            if upward { y = pt.y }
        case .beside(let r):
            x = r.maxX + 6
            if x + size.width > screen.maxX { x = r.minX - 6 - size.width }
            y = r.maxY - size.height
            upward = false
        }
        x = min(max(x, screen.minX + 4), screen.maxX - size.width - 4)
        y = min(max(y, screen.minY + 4), screen.maxY - size.height - 4)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func watch(menu: Bool) {
        // A click outside closes. The click still goes where it was aimed, except on the view that
        // opened the menu: there it would open it again.
        add(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] e in
            guard let self, let p = self.panel else { return e }
            if e.window === p { return e }
            let onAnchor: Bool = {
                guard case .below(let r) = self.place, let w = e.window else { return false }
                return r.contains(w.convertPoint(toScreen: e.locationInWindow))
            }()
            self.close()
            return onAnchor ? nil : e
        })
        add(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        })
        add(NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            self?.key(e, menu: menu) == true ? nil : e
        })
    }

    private func add(_ m: Any?) { if let m { monitors.append(m) } }

    /// Esc closes; a menu takes the rest of its keys while it is open, as a real menu does.
    private func key(_ e: NSEvent, menu: Bool) -> Bool {
        if e.keyCode == 53 { close(); return true }
        guard menu, let st = state, let items = items.map({ uniqued($0()) }) else { return false }
        if !e.modifierFlags.intersection([.command, .control]).isEmpty { close(); return false }
        _ = st.key(e, in: items)
        return true
    }
}

// MARK: - Anchors

/// A plain NSView behind a SwiftUI view, to find its frame on screen when a menu opens.
final class MenuAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    var screenFrame: NSRect? {
        guard let w = window else { return nil }
        return w.convertToScreen(convert(bounds, to: nil))
    }
}

private struct MenuAnchor: NSViewRepresentable {
    let view: MenuAnchorView
    func makeNSView(context: Context) -> MenuAnchorView { view }
    func updateNSView(_ nsView: MenuAnchorView, context: Context) {}
}

/// Opens a menu or panel under a view while `isPresented` is true; closing either way sets it back.
private struct PanelPresenter: ViewModifier {
    @Binding var isPresented: Bool
    let open: (MenuAnchorView, @escaping () -> Void) -> Void
    @State private var anchor = MenuAnchorView()
    @State private var token: UUID?

    func body(content: Content) -> some View {
        content
            // Snapshots (revealAtOnce) leave the anchor out: ImageRenderer draws an AppKit view as a
            // yellow box, which showed at the corners of every eval card.
            .background { if !revealAtOnce { MenuAnchor(view: anchor) } }
            .onChange(of: isPresented, initial: true) { _, on in
                if on {
                    open(anchor) { isPresented = false }
                    token = MenuPanel.shared.token
                } else if token == MenuPanel.shared.token, MenuPanel.shared.isOpen {
                    MenuPanel.shared.close()
                }
            }
    }
}

extension View {
    /// A Takes menu under this view while `isPresented` is true.
    func takesMenu(isPresented: Binding<Bool>, width: CGFloat? = nil, @MenuBuilder _ content: @escaping () -> [MenuItem]) -> some View {
        modifier(MenuHost(isPresented: isPresented, width: width, content: content))
    }

    /// A panel (any view) under this view, or beside it with `edge: .trailing`, while `isPresented` is true.
    func takesPopover<V: View>(isPresented: Binding<Bool>, edge: Edge = .bottom, @ViewBuilder _ content: @escaping () -> V) -> some View {
        modifier(PopoverHost(isPresented: isPresented, edge: edge, content: { AnyView(content()) }))
    }

    /// A panel for an optional item, like `.popover(item:)`.
    func takesPopover<Item: Identifiable, V: View>(item: Binding<Item?>, edge: Edge = .bottom,
                                                   @ViewBuilder _ content: @escaping (Item) -> V) -> some View {
        let shown = Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
        return modifier(PopoverHost(isPresented: shown, edge: edge, content: {
            if let i = item.wrappedValue { AnyView(content(i)) } else { AnyView(EmptyView()) }
        }))
    }

    /// A Takes right-click menu. The rows are built when the click comes, so they see the current
    /// selection. Right-click on text inside this view still gets the system's text menu.
    func takesContextMenu(@MenuBuilder _ content: @escaping () -> [MenuItem]) -> some View {
        modifier(ContextHost(content: content))
    }
}

private struct MenuHost: ViewModifier {
    @Binding var isPresented: Bool
    let width: CGFloat?
    let content: () -> [MenuItem]
    @Environment(AppModel.self) private var app: AppModel?
    func body(content body: Content) -> some View {
        body.modifier(PanelPresenter(isPresented: $isPresented) { anchor, closed in
            MenuPanel.shared.show(menu: content, at: .below(anchor.screenFrame ?? .zero), width: width, app: app, onClose: closed)
        })
    }
}

private struct PopoverHost: ViewModifier {
    @Binding var isPresented: Bool
    let edge: Edge
    let content: () -> AnyView
    @Environment(AppModel.self) private var app: AppModel?
    func body(content body: Content) -> some View {
        body.modifier(PanelPresenter(isPresented: $isPresented) { anchor, closed in
            let r = anchor.screenFrame ?? .zero
            let place: MenuPanel.Place = edge == .trailing || edge == .leading ? .beside(r) : .below(r)
            MenuPanel.shared.show(panel: AnyView(PopoverChrome(content: content)), at: place, app: app, onClose: closed)
        })
    }
}

/// A panel's frame. The content keeps its own padding; this adds the paper and the hairline.
private struct PopoverChrome: View {
    let content: () -> AnyView
    var body: some View {
        content().fixedSize().menuChrome()
    }
}

/// A click menu: the label is the button (was `Menu { } label: { }`).
struct TakesMenuButton<Label: View>: View {
    var width: CGFloat? = nil
    var help: String? = nil
    @ViewBuilder let label: () -> Label
    @MenuBuilder let content: () -> [MenuItem]
    @State private var open = false

    init(width: CGFloat? = nil, help: String? = nil, @ViewBuilder label: @escaping () -> Label,
         @MenuBuilder content: @escaping () -> [MenuItem]) {
        self.width = width
        self.help = help
        self.label = label
        self.content = content
    }

    var body: some View {
        Button { open.toggle() } label: { label() }
            .buttonStyle(.plain)
            .takesMenu(isPresented: $open, width: width, content)
            .help(help ?? "")
    }
}

// MARK: - Right-click

/// Every view with a Takes right-click menu leaves one of these behind it. One event monitor
/// finds the smallest one under the pointer, so a tile inside a list gets the tile's menu.
final class MenuRegionView: NSView {
    var content: (() -> [MenuItem])?
    weak var app: AppModel?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { ContextMenus.shared.add(self) }
    }
}

@MainActor
final class ContextMenus {
    static let shared = ContextMenus()
    private let regions = NSHashTable<MenuRegionView>.weakObjects()
    private var monitor: Any?

    func add(_ v: MenuRegionView) {
        regions.add(v)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { e in
            ContextMenus.shared.open(e) ? nil : e
        }
    }

    /// The region for a click, or nil to leave the click alone.
    func region(for e: NSEvent) -> MenuRegionView? {
        guard let w = e.window else { return nil }
        // Text keeps the system menu (spelling, Look Up, Services).
        if let hit = w.contentView?.hitTest(w.contentView!.convert(e.locationInWindow, from: nil)), hit is NSTextView { return nil }
        var best: (MenuRegionView, CGFloat)?
        for v in regions.allObjects where v.window === w && !v.isHiddenOrHasHiddenAncestor && v.content != nil {
            let pt = v.convert(e.locationInWindow, from: nil)
            // In a scroll view visibleRect is the whole clip view, not the view's own frame, so
            // every row of a list claimed every point and the shortest won: a right-click on a
            // session opened its project's menu, and the user trashed the project (2026-10-22).
            guard v.bounds.contains(pt), v.visibleRect.contains(pt) else { continue }
            let area = v.bounds.width * v.bounds.height
            if best == nil || area < best!.1 { best = (v, area) }
        }
        return best?.0
    }

    private func open(_ e: NSEvent) -> Bool {
        let right = e.type == .rightMouseDown || (e.type == .leftMouseDown && e.modifierFlags.contains(.control))
        guard right, let w = e.window, let v = region(for: e), let content = v.content else { return false }
        if uniqued(content()).isEmpty { return false }
        MenuPanel.shared.show(menu: content, at: .at(w.convertPoint(toScreen: e.locationInWindow)), app: v.app)
        return true
    }
}

private struct MenuRegion: NSViewRepresentable {
    let content: (() -> [MenuItem])?
    let app: AppModel?
    func makeNSView(context: Context) -> MenuRegionView {
        let v = MenuRegionView()
        v.content = content
        v.app = app
        return v
    }
    func updateNSView(_ v: MenuRegionView, context: Context) {
        v.content = content
        v.app = app
    }
}

private struct ContextHost: ViewModifier {
    let content: () -> [MenuItem]
    @Environment(AppModel.self) private var app: AppModel?
    @Environment(\.menusLive) private var live
    func body(content body: Content) -> some View {
        body.background(MenuRegion(content: live ? content : nil, app: app))
    }
}

private struct MenusLiveKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    /// False in a layer kept under another one: its right-click menus are off.
    var menusLive: Bool {
        get { self[MenusLiveKey.self] }
        set { self[MenusLiveKey.self] = newValue }
    }
}

extension View {
    /// allowsHitTesting for a layer that stays mounted under another one, with its right-click
    /// menus off too. 2026-10-13: the Record screen kept under Assets answered right-clicks on the
    /// asset tiles (the smallest menu region won), so a tile had no menu and could not be trashed.
    func liveLayer(_ on: Bool) -> some View {
        allowsHitTesting(on).transformEnvironment(\.menusLive) { $0 = $0 && on }
    }
}

// MARK: - Switch

/// Two to four choices side by side (was the stock segmented control): a well with the picked
/// one raised. Used for Read / Edit, text size, sort orders.
struct TakesSwitch<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    var fill = false
    @Namespace private var ns
    @State private var hover: T?

    init(selection: Binding<T>, options: [(T, String)], fill: Bool = false) {
        _selection = selection
        self.options = options
        self.fill = fill
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                let on = value == selection
                Button { withAnimation(Theme.motion) { selection = value } } label: {
                    Text(title).font(Theme.sans(12, .medium)).lineLimit(1)
                        .foregroundStyle(on || hover == value ? Theme.ink : Theme.muted)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: fill ? .infinity : nil, minHeight: 24)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.raised)
                                    .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                                    .matchedGeometryEffect(id: "on", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hover = $0 ? value : (hover == value ? nil : hover) }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.border))
        .fixedSize(horizontal: !fill, vertical: true)
    }
}

extension TakesSwitch where T: CaseIterable & Identifiable, T.AllCases: RandomAccessCollection {
    init(selection: Binding<T>, title: (T) -> String, fill: Bool = false) {
        self.init(selection: selection, options: T.allCases.map { ($0, title($0)) }, fill: fill)
    }
}

// MARK: - Confirm

/// A confirm card in the panel look (was `.alert` and `NSAlert`): title, a line, a field or a
/// check, and two buttons. Return confirms, Esc cancels.
struct TakesConfirm: View {
    let title: String
    var message: String? = nil
    var confirm: String = "OK"
    var danger = false
    var field: Binding<String>? = nil
    var fieldPrompt = ""
    var check: (title: String, value: Binding<Bool>)? = nil
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(Theme.display(17)).foregroundStyle(Theme.ink)
            if let message {
                Text(message).font(Theme.sans(12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            if let field {
                TextField(fieldPrompt, text: field)
                    .textFieldStyle(.plain).font(Theme.sans(13))
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                    .focused($focused)
                    .onSubmit(onConfirm)
            }
            if let check {
                Button { check.value.wrappedValue.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: check.value.wrappedValue ? "checkmark.square.fill" : "square")
                            .font(.system(size: 13)).foregroundStyle(check.value.wrappedValue ? Theme.accent : Theme.muted)
                        Text(check.title).font(Theme.sans(12.5)).foregroundStyle(Theme.ink)
                    }
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(AccentButtonStyle(kind: .quiet)).keyboardShortcut(.cancelAction)
                Button(confirm, action: onConfirm).buttonStyle(AccentButtonStyle(kind: danger ? .solid : .accent))
                    .keyboardShortcut(.defaultAction)
                    .disabled(field?.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty ?? false)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 340)
        .background(Theme.paper)
        .onAppear { focused = true }
    }
}
