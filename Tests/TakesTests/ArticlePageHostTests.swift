import AppKit
import SwiftUI
import Testing
import WebKit
@testable import Takes

/// The article page is loaded once and handed from one article view to the next (2026-10-04).
@MainActor
@Suite struct ArticlePageHostTests {
    private func host(_ view: some View) -> (NSWindow, NSHostingView<AnyView>) {
        let h = NSHostingView(rootView: AnyView(view.frame(width: 700, height: 600)))
        h.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
        let w = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 700, height: 600), styleMask: [.borderless],
                         backing: .buffered, defer: false)
        w.contentView = h
        w.orderFrontRegardless()
        return (w, h)
    }

    private func text(_ web: WKWebView, until want: String) async -> String {
        var last = ""
        for _ in 0..<100 {
            last = ((try? await web.evaluateJavaScript("document.querySelector('article')?.innerText ?? ''")) as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if last.contains(want) || (want == "@@" && last.isEmpty) { return last }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return last
    }

    private func webs(in v: NSView) -> [WKWebView] {
        (v as? WKWebView).map { [$0] } ?? v.subviews.flatMap(webs)
    }

    private func settle(_ h: NSView) { for _ in 0..<4 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)); h.layoutSubtreeIfNeeded() } }

    private func article(_ md: String) -> ArticleView {
        ArticleView(markdown: md, head: ArticleHead(nil), session: URL(fileURLWithPath: NSTemporaryDirectory()))
    }

    @Test func theNextArticleUsesALoadedPage() async {
        let (w, h) = host(article("First article body.\n"))
        settle(h)
        guard let first = webs(in: h).first else { Issue.record("no web view"); return }
        #expect(await text(first, until: "First").contains("First article"))

        // Typing, then a switch before the page sends it: nothing late reaches the next article.
        _ = try? await first.evaluateJavaScript("document.querySelector('article p').textContent += ' typed'; "
                                                + "document.querySelector('article').dispatchEvent(new Event('input')); 1")
        // Another platform shows: the article view goes, and its page waits, loaded.
        h.rootView = AnyView(Color.clear.frame(width: 700, height: 600))
        settle(h)
        #expect(ArticlePageHost.idle.contains { $0.web === first })
        #expect(await text(first, until: "@@").isEmpty)   // emptied, not the old article

        // The next article view: the same web view, the new text, and quickly.
        let t = CFAbsoluteTimeGetCurrent()
        h.rootView = AnyView(article("Second article body.\n").frame(width: 700, height: 600))
        settle(h)
        #expect(webs(in: h).first === first)
        #expect(await text(first, until: "Second").contains("Second article"))
        let ms = (CFAbsoluteTimeGetCurrent() - t) * 1000
        #expect(ms < 400)
        var changed: [String] = []
        h.rootView = AnyView(ArticleView(markdown: "Second article body.\n", head: ArticleHead(nil),
                                         session: URL(fileURLWithPath: NSTemporaryDirectory()), onChange: { changed.append($0) })
            .frame(width: 700, height: 600))
        settle(h)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(changed.isEmpty)
        print(String(format: "article shown again in %.0f ms", ms))

        // A session switch: the new view comes before the old one goes. It gets a second page, and
        // the switch after that finds both loaded.
        h.rootView = AnyView(article("Third article body.\n").id("b").frame(width: 700, height: 600))
        settle(h)
        guard let second = webs(in: h).first else { Issue.record("no web view"); return }
        #expect(await text(second, until: "Third").contains("Third article"))
        h.rootView = AnyView(article("Fourth article body.\n").id("c").frame(width: 700, height: 600))
        settle(h)
        let fourth = webs(in: h).first
        #expect(fourth === first || fourth === second)
        if let fourth { #expect(await text(fourth, until: "Fourth").contains("Fourth article")) }

        // Two at once each show their own article.
        h.rootView = AnyView(HStack { article("Left article body.\n"); article("Right article body.\n") }.frame(width: 700, height: 600))
        settle(h)
        let two = webs(in: h)
        #expect(two.count == 2)
        if two.count == 2 {
            // Each shows its own (a reused page shows the old article until it renders).
            let a = await text(two[0], until: "Left"), b = await text(two[1], until: "Right")
            #expect(a.contains("Left article") && b.contains("Right article"))
        }
        w.orderOut(nil)
    }
}
