import SwiftUI

// Page motion (2026-10-04): pages come in from a soft blur, not a cut. Short and calm, never bouncy.
// One-shot animations only: an endless SwiftUI animation redraws the window every frame (Motion.swift).
//
// The rule for every page (2026-10-09, AGENTS.md "Motion"):
// - A board arrives through `.transition(.page)`, set once where the boards switch (Views.swift).
// - A tab that stays mounted uses `.pageFade(shown)`.
// - The page's parts arrive in order with `.arrive(0)`, `.arrive(1)`… when they first show.
// - No spinner while a page reads its data: draw nothing, then let the parts arrive.

extension Animation {
    /// A page or section coming into view.
    static let page = Animation.smooth(duration: 0.34)
}

/// A page that stays mounted while hidden: it fades and sharpens in, and blurs out.
/// Only these modifiers animate, not the views the page builds.
struct PageFade: ViewModifier {
    let on: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A page opened for the first time arrives too, not only one coming back.
    @State private var mounted = false

    func body(content: Content) -> some View {
        let shown = on && mounted
        content
            .animation(.page) {
                $0.opacity(shown ? 1 : 0)
                    .blur(radius: shown || reduceMotion ? 0 : 10)
                    .scaleEffect(shown || reduceMotion ? 1 : 0.992)
            }
            .onAppear { mounted = true }
    }
}

/// One item of a group arriving: blur, rise and fade, a little after the item before it.
struct Arrive: ViewModifier {
    let on: Bool
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .animation(.smooth(duration: 0.6).delay(Double(index) * 0.06)) {
                $0.opacity(on ? 1 : 0)
                    .blur(radius: on || reduceMotion ? 0 : 8)
                    .offset(y: on || reduceMotion ? 0 : 12)
            }
    }
}

/// A board coming in or going: the page's blur, rise and fade, as a transition.
struct PageIn: ViewModifier {
    let on: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0)
            .blur(radius: on || reduceMotion ? 0 : 10)
            .offset(y: on || reduceMotion ? 0 : 8)
    }
}

extension AnyTransition {
    /// Every board comes in and goes this way.
    static var page: AnyTransition { .modifier(active: PageIn(on: false), identity: PageIn(on: true)) }
}

extension View {
    func pageFade(_ on: Bool) -> some View { modifier(PageFade(on: on)) }
    func arrive(_ on: Bool, _ index: Int = 0) -> some View { modifier(Arrive(on: on, index: index)) }
}

/// Content that blurs in when it first shows and again each time `key` changes: a platform or a
/// variant of the post. The bar above it stays put. It waits until `ready` (the post is read), plus
/// `settle` seconds for media inside to load, so a preview arrives whole instead of in pieces.
/// Snapshots draw in a window off every screen, where animations never run: they show content at once.
@MainActor var revealAtOnce = false

struct Reveal<Key: Equatable>: ViewModifier {
    let key: Key
    var ready = true
    var settle: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    /// The latest reveal; an older one that is still waiting does nothing.
    @State private var turn = 0

    func body(content: Content) -> some View {
        content
            .animation(.page) {
                $0.opacity(shown || revealAtOnce ? 1 : 0)
                    .blur(radius: shown || revealAtOnce || reduceMotion ? 0 : 10)
                    .offset(y: shown || revealAtOnce || reduceMotion ? 0 : 8)
            }
            .onAppear(perform: show)
            .onChange(of: ready, show)
            .onChange(of: key) {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { shown = false }
                show()
            }
    }

    private func show() {
        guard ready else { return }
        turn += 1
        let mine = turn
        // One run loop at least: the hidden state must draw before the reveal animates.
        DispatchQueue.main.asyncAfter(deadline: .now() + max(settle, 0.01)) { if mine == turn { shown = true } }
    }
}

extension View {
    func reveal<Key: Equatable>(on key: Key, ready: Bool = true, settle: Double = 0) -> some View {
        modifier(Reveal(key: key, ready: ready, settle: settle))
    }
}

/// A part of a page arriving when it first shows: blur, rise and fade, after the parts before it.
/// `index` sets the order. Onboarding slows it with its pace.
struct ArriveOnShow: ViewModifier {
    @Environment(\.accessibilityReduceMotion) var still
    let index: Int
    @State private var on = false

    func body(content: Content) -> some View {
        // One run loop first: the hidden state must draw before it animates.
        let shown = on || revealAtOnce
        content
            .animation(.smooth(duration: 0.6 * Onboarding.pace).delay(Double(index) * 0.06 * Onboarding.pace)) {
                $0.opacity(shown ? 1 : 0)
                    .blur(radius: shown || still ? 0 : 8)
                    .offset(y: shown || still ? 0 : 12)
            }
            .onAppear { DispatchQueue.main.async { on = true } }
    }
}

extension View {
    func arrive(_ index: Int) -> some View { modifier(ArriveOnShow(index: index)) }
}
