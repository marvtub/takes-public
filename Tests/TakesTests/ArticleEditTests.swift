import Foundation
import Testing
import WebKit
@testable import Takes

// 2026-10-04: the article is written in the blog page itself. Untouched blocks must come back
// as their exact markdown; only a changed block is written again.

@MainActor
@Suite struct ArticleEditTests {
    final class Inbox: NSObject, WKScriptMessageHandler {
        var got: [(String, Any)] = []
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { got.append((m.name, m.body)) }
    }

    func page(_ md: String) async throws -> (WKWebView, Inbox) {
        let config = WKWebViewConfiguration()
        let inbox = Inbox()
        config.setURLSchemeHandler(SessionFiles(), forURLScheme: "takes")
        for n in ArticleView.Coordinator.messages { config.userContentController.add(inbox, name: n) }
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 1200), configuration: config)
        web.loadHTMLString(ArticlePage.html, baseURL: URL(string: "takes://session/"))
        for _ in 0..<40 where !inbox.got.contains(where: { $0.0 == "ready" }) { try await Task.sleep(for: .milliseconds(100)) }
        _ = try await web.evaluateJavaScript("takes.render(\(ArticleView.Coordinator.blocks(md)), {}); 1")
        return (web, inbox)
    }

    func markdown(_ web: WKWebView) async throws -> String {
        try await web.evaluateJavaScript("takes.markdown()") as? String ?? ""
    }

    @Test func untouchedTextKeepsItsSource() async throws {
        let md = ArticleTests.sample
        let (web, _) = try await page(md)
        #expect(try await markdown(web) == Article.blocks(md).map(\.md).joined(separator: "\n\n"))
    }

    @Test func aChangedParagraphIsWrittenAgain() async throws {
        let md = "## Why\n\nOld *text* here.\n\n<Callout type=\"tip\">\nKeep **me**.\n</Callout>\n\n- one\n- two"
        let (web, _) = try await page(md)
        _ = try await web.evaluateJavaScript("""
            document.querySelector('article p').innerHTML = 'New <strong>bold</strong>, <em>it</em> and <a href="https://example.com/blog/x">a link</a>.';
            const li = document.createElement('li'); li.textContent = 'three'; document.querySelector('article ul').append(li);
            const p = document.createElement('p'); p.innerHTML = 'A <code>new</code> one'; document.querySelector('article').append(p); 1
            """)
        #expect(try await markdown(web) == "## Why\n\nNew **bold**, _it_ and [a link](/blog/x).\n\n<Callout type=\"tip\">\nKeep **me**.\n</Callout>\n\n- one\n- two\n- three\n\nA `new` one")
    }

    @Test func markdownMarksAtTheStartMakeBlocks() async throws {
        let (web, _) = try await page("First.")
        for (typed, want) in [("## Head", "## Head"), ("- item", "- item"), ("> said", "> said")] {
            _ = try await web.evaluateJavaScript("""
                { const p = document.createElement('p'); p.textContent = \(ArticleView.Coordinator.js(typed));
                document.querySelector('article').append(p);
                const r = document.createRange(); r.setStart(p.firstChild, p.firstChild.length); r.collapse(true);
                getSelection().removeAllRanges(); getSelection().addRange(r); shortcut(); } 1
                """)
            #expect(try await markdown(web).hasSuffix(want))
        }
        #expect(try await web.evaluateJavaScript("document.querySelector('article h2')?.textContent") as? String == "Head")
    }

    @Test func aComponentComesInAsItsSource() async throws {
        let (web, inbox) = try await page("Intro.")
        _ = try await web.evaluateJavaScript("takes.insert('<TLDR>\\n- One.\\n</TLDR>'); 1")
        try await Task.sleep(for: .milliseconds(100))
        let commit = inbox.got.last { $0.0 == "commit" }?.1 as? String
        #expect(commit == "Intro.\n\n<TLDR>\n- One.\n</TLDR>")
    }
}
