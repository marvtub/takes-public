import SwiftUI

// Takes's own menus and confirms on the phone (2026-10-09), drawn like the Mac's More popover
// (Shell.swift MorePanel): paper, a hairline, rows with a muted icon and Inter type, lists that
// open in place under their row, red for the one that trashes. No system Menu, context menu or
// alert: The user rejected the stock look.

/// A paper card that floats under the button that opened it. A tap outside closes it.
struct FloatingPanel<Content: View>: View {
    @Binding var open: Bool
    var alignment: Alignment = .topTrailing
    var top: CGFloat = 54
    var width: CGFloat = 300
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack(alignment: alignment) {
            Color.black.opacity(0.001).ignoresSafeArea()
                .onTapGesture { withAnimation(Brand.quick) { open = false } }
            VStack(alignment: .leading, spacing: 1) { content() }
                .padding(6)
                .frame(width: width)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border, lineWidth: 0.5))
            .shadow(color: Palette.shadow, radius: 10, y: 4)
            .padding(.top, top).padding(.horizontal, 12)
            .transition(.scale(scale: 0.94, anchor: alignment == .topLeading ? .topLeading : .topTrailing).combined(with: .opacity))
        }
    }
}

/// One row of a panel: a muted icon, the words, and a press well.
struct PanelRow: View {
    let icon: String
    let title: String
    var danger = false
    var checked = false
    var enabled = true
    var detail: String? = nil
    let action: () -> Void

    var body: some View {
        Button { Brand.select(); action() } label: {
            HStack(spacing: 11) {
                Image(systemName: icon).font(.system(size: 14, weight: .medium))
                    .foregroundStyle(danger ? Palette.danger : Palette.muted).frame(width: 20)
                Text(title).font(.inter(.callout)).foregroundStyle(danger ? Palette.danger : Palette.ink).lineLimit(1)
                Spacer(minLength: 0)
                if let detail { Text(detail).font(.inter(.footnote)).foregroundStyle(Palette.faint).lineLimit(1) }
                if checked { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.accent) }
            }
            .padding(.horizontal, 10).frame(height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPress())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(title)
    }
}

/// A row whose list opens in place under it, as "Move to project" does on the Mac.
struct PanelGroup<Content: View>: View {
    let icon: String
    let title: String
    @Binding var open: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button { Brand.select(); withAnimation(Brand.quick) { open.toggle() } } label: {
                HStack(spacing: 11) {
                    Image(systemName: icon).font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.muted).frame(width: 20)
                    Text(title).font(.inter(.callout)).foregroundStyle(Palette.ink)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.faint)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, 10).frame(height: 42)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowPress())
            .accessibilityLabel(title)
            if open {
                VStack(alignment: .leading, spacing: 1) { content() }
                    .padding(.leading, 30)
                    .transition(.opacity)
            }
        }
    }
}

/// A plain choice inside a group.
struct PanelChoice: View {
    let title: String
    var checked = false
    let action: () -> Void

    var body: some View {
        Button { Brand.select(); action() } label: {
            HStack {
                Text(title).font(.inter(.subheadline)).foregroundStyle(Palette.ink).lineLimit(1)
                Spacer(minLength: 0)
                if checked { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.accent) }
            }
            .padding(.horizontal, 10).frame(height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPress())
        .accessibilityLabel(title)
    }
}

struct PanelDivider: View {
    var body: some View { Rectangle().fill(Palette.border).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 5) }
}

// MARK: - Confirm and name

/// What a confirm asks: the title, a line, the button, and what it does.
struct Confirm: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var button: String
    var danger = true
    var run: () async -> String?
}

/// A centered card over a dimmed screen: Cancel and the action. The action's error stays on the
/// card; it closes once the Mac did it.
struct ConfirmCard: View {
    let confirm: Confirm
    let close: () -> Void
    @State private var busy = false
    @State private var failed: String?

    var body: some View {
        CardOverlay(close: close) {
            VStack(alignment: .leading, spacing: 10) {
                Text(confirm.title).font(.nunito(size: 20, relativeTo: .title3)).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(confirm.message).font(.inter(.subheadline)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let failed {
                    Label(failed, systemImage: "exclamationmark.triangle").font(.inter(.footnote, .medium)).foregroundStyle(Palette.danger)
                }
                HStack(spacing: 8) {
                    Spacer()
                    Button("Cancel", action: close).buttonStyle(.pill(.quiet, small: true))
                    Button {
                        busy = true
                        Task {
                            if let e = await confirm.run() { failed = e; busy = false } else { close() }
                        }
                    } label: {
                        Text(busy ? "Working…" : confirm.button)
                    }
                    .buttonStyle(.pill(confirm.danger ? .record : .ink, small: true))
                    .disabled(busy)
                }
                .padding(.top, 6)
            }
        }
    }
}

/// A name to type: a take, a session, a project or a variant.
struct NameAsk: Identifiable {
    let id = UUID()
    var title: String
    var name: String
    var button = "Rename"
    var run: (String) async -> String?
}

struct NameCard: View {
    let ask: NameAsk
    let close: () -> Void
    @State private var name = ""
    @State private var busy = false
    @State private var failed: String?
    @FocusState private var focused: Bool

    var body: some View {
        CardOverlay(close: close) {
            VStack(alignment: .leading, spacing: 12) {
                Text(ask.title).font(.nunito(size: 20, relativeTo: .title3)).foregroundStyle(Palette.ink)
                TextField("Name", text: $name)
                    .font(.inter(.callout)).foregroundStyle(Palette.ink)
                    .focused($focused).submitLabel(.done)
                    .onSubmit(save)
                    .padding(.horizontal, 12).frame(height: 42)
                    .background(Palette.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.accent.opacity(focused ? 0.5 : 0), lineWidth: 1.5))
                    .accessibilityIdentifier("name-field")
                if let failed {
                    Label(failed, systemImage: "exclamationmark.triangle").font(.inter(.footnote, .medium)).foregroundStyle(Palette.danger)
                }
                HStack(spacing: 8) {
                    Spacer()
                    Button("Cancel", action: close).buttonStyle(.pill(.quiet, small: true))
                    Button(busy ? "Saving…" : ask.button, action: save)
                        .buttonStyle(.pill(.ink, small: true))
                        .disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear { name = ask.name; focused = true }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !busy else { return }
        busy = true
        Task {
            if let e = await ask.run(n) { failed = e; busy = false } else { close() }
        }
    }
}

/// The dimmed screen and the paper card in its middle.
struct CardOverlay<Content: View>: View {
    let close: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            Palette.ink.opacity(0.28).ignoresSafeArea().onTapGesture(perform: close)
            content()
                .padding(18)
                .frame(maxWidth: 340, alignment: .leading)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.border, lineWidth: 0.5))
                .shadow(color: Palette.shadow, radius: 16, y: 6)
                .padding(24)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
    }
}

extension View {
    /// The confirm and name cards, over this screen.
    func asks(confirm: Binding<Confirm?>, name: Binding<NameAsk?>) -> some View {
        overlay {
            ZStack {
                if let c = confirm.wrappedValue {
                    ConfirmCard(confirm: c) { withAnimation(Brand.quick) { confirm.wrappedValue = nil } }.id(c.id)
                }
                if let n = name.wrappedValue {
                    NameCard(ask: n) { withAnimation(Brand.quick) { name.wrappedValue = nil } }.id(n.id)
                }
            }
            .animation(Brand.quick, value: confirm.wrappedValue?.id)
            .animation(Brand.quick, value: name.wrappedValue?.id)
        }
    }
}

/// A short line at the foot of the screen that goes away by itself, as the Mac's toasts do.
struct Toast: View {
    @Binding var text: String?

    var body: some View {
        if let text {
            Text(text).font(.inter(.footnote, .medium)).foregroundStyle(Palette.paper)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Palette.ink, in: Capsule())
                .padding(.bottom, 70)
                .transition(.opacity.combined(with: .offset(y: 6)))
                .task(id: text) {
                    try? await Task.sleep(for: .seconds(2.6))
                    withAnimation(Brand.quick) { self.text = nil }
                }
        }
    }
}

/// A choice as a capsule: the Mac's ToggleChip (Views.swift). On is the soft accent with a check.
struct ToggleChip: View {
    let title: String
    var icon: String? = nil
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button { Brand.select(); withAnimation(Brand.quick) { action() } } label: {
            HStack(spacing: 5) {
                if on || icon != nil {
                    Image(systemName: on ? "checkmark" : icon ?? "").font(.system(size: 11, weight: .bold))
                        .contentTransition(.symbolEffect(.replace))
                }
                Text(title).font(.inter(.footnote, .medium)).lineLimit(1)
            }
            .fixedSize()
            .foregroundStyle(on ? Palette.accentInk : Palette.muted)
            .padding(.horizontal, 12).frame(height: 34)
            .background(Capsule().fill(on ? Palette.accentSoft : .clear))
            .overlay(Capsule().strokeBorder(on ? .clear : Palette.border, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
