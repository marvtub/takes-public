import SwiftUI
import WebKit
import UniformTypeIdentifiers

// The article as your blog shows a post (2026-10-04): the blog's page, type and components,
// copied from the site's globals.css and components/mdx. A web view, because the blog is a web
// page: Satoshi, 18 px text in a 624 px column, the orange accent.
//
// The page loads once; each change only swaps the article (no flash, the scroll stays). Pictures
// with a relative path come from the session, through the takes: scheme, as do the fonts.

/// What the page header shows: the post's front matter.
struct ArticleHead: Equatable {
    var title = ""
    var description = ""
    var category = ""
    var date = ""
    var slug = ""

    init(_ c: PostFile.Content?) {
        guard let c else { return }
        title = c.title
        description = c.meta["description"] ?? ""
        category = c.meta["category"] ?? ""
        slug = c.meta["slug"] ?? Article.slug(c.title)
        let at = c.at ?? Date()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMMM d, yyyy"
        date = f.string(from: at)
    }

    var json: String {
        let d: [String: String] = ["title": title, "description": description, "category": category.lowercased(),
                                   "date": date, "slug": slug.count > 30 ? String(slug.prefix(27)) + "..." : slug]
        return String(data: (try? JSONSerialization.data(withJSONObject: d)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }
}

struct ArticleView: NSViewRepresentable {
    let markdown: String
    let head: ArticleHead
    let session: URL
    var highlights: [String] = []
    var reveal: (quote: String, token: Int)?
    var onSelect: (String) -> Void = { _ in }
    /// A click on a marked comment quote.
    var onPick: (String) -> Void = { _ in }
    /// The markdown after the user typed in the page.
    var onChange: (String) -> Void = { _ in }
    /// Title and description typed in the page's head.
    var onHead: (_ title: String, _ description: String) -> Void = { _, _ in }
    /// A category picked in the page ("" for none).
    var onCategory: (String) -> Void = { _ in }
    /// A component to put in at the caret, once per token.
    var insert: (md: String, token: Int)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let c = context.coordinator
        // Loaded pages are kept (2026-10-04): a new web view took 180-400 ms to load and started
        // its own web process (about 33 MB) on each switch to Article; a loaded one renders in 2 ms.
        let page = ArticlePageHost.take()
        page.adopt(c)
        page.files.session = session
        c.page = page
        c.files = page.files
        c.web = page.web
        return page.web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let c = context.coordinator
        c.parent = self
        c.files?.session = session
        c.push()
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.page?.release(coordinator)
    }

    final class Coordinator: NSObject {
        var parent: ArticleView
        weak var web: WKWebView?
        var files: SessionFiles?
        var page: ArticlePageHost?
        static let messages = ["sel", "pick", "ready", "change", "commit", "head", "cat"]
        var ready = false
        /// What the page shows: its markdown re-renders the body, its head only the head.
        private var shownMarkdown: String?
        private var shownHead: ArticleHead?
        private var lastInsert = 0
        private var lit: [String]?
        private var lastReveal = 0
        /// Typing renders at most every 150 ms.
        private var pending: DispatchWorkItem?

        init(_ p: ArticleView) { parent = p }

        /// The page lost what it showed: the next push renders it all again.
        func forget() {
            shownMarkdown = nil
            shownHead = nil
            lit = nil
        }

        func push() {
            guard ready, let web else { return }
            if shownMarkdown != parent.markdown {
                let first = shownMarkdown == nil
                shownMarkdown = parent.markdown
                shownHead = parent.head
                pending?.cancel()
                let md = parent.markdown, head = parent.head
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    web.evaluateJavaScript("takes.render(\(Self.blocks(md)), \(head.json))")
                    self.lit = nil
                    self.mark()
                }
                pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + (first ? 0 : 0.15), execute: work)
            } else {
                if shownHead != parent.head {
                    shownHead = parent.head
                    web.evaluateJavaScript("takes.head(\(parent.head.json))")
                }
                mark()
            }
            if let ins = parent.insert, ins.token != lastInsert {
                lastInsert = ins.token
                web.evaluateJavaScript("takes.insert(\(Self.js(ins.md)))")
            }
            if let r = parent.reveal, r.token != lastReveal {
                lastReveal = r.token
                web.evaluateJavaScript("takes.reveal(\(Self.js(r.quote)))")
            }
        }

        private func mark() {
            guard let web, lit != parent.highlights else { return }
            lit = parent.highlights
            let list = String(data: (try? JSONSerialization.data(withJSONObject: parent.highlights)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
            web.evaluateJavaScript("takes.mark(\(list))")
        }

        static func blocks(_ md: String) -> String {
            let list = Article.blocks(md).map { ["html": $0.html, "md": $0.md] }
            return String(data: (try? JSONSerialization.data(withJSONObject: list)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        }

        static func js(_ s: String) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
            let arr = String(data: data, encoding: .utf8) ?? "[\"\"]"
            return String(arr.dropFirst().dropLast())
        }

        func receive(_ message: WKScriptMessage) {
            let text = message.body as? String ?? ""
            switch message.name {
            case "ready": ready = true; push()
            case "sel": parent.onSelect(text)
            case "pick": parent.onPick(text)
            case "change":
                // The page already shows it: no render, so the caret stays.
                shownMarkdown = text
                if text != parent.markdown { parent.onChange(text) }
            case "commit":
                // A component changed or came in: render it.
                if text != parent.markdown { parent.onChange(text) }
                shownMarkdown = text
                pending?.cancel()
                web?.evaluateJavaScript("takes.render(\(Self.blocks(text)), \(parent.head.json))")
                lit = nil
                mark()
            case "head":
                let d = message.body as? [String: Any] ?? [:]
                parent.onHead(d["title"] as? String ?? "", d["description"] as? String ?? "")
            case "cat": parent.onCategory(text)
            default: break
            }
        }

    }
}

/// The article page's web view, kept loaded between article views. It hands the page's messages
/// to the view that shows it now; a page left with no view waits for the next one.
final class ArticlePageHost: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    /// Loaded pages with no view. Two: on a session switch the new article view comes before the
    /// old one goes, so the two take turns.
    private(set) static var idle: [ArticlePageHost] = []
    static let keep = 2

    static func take() -> ArticlePageHost { idle.popLast() ?? ArticlePageHost() }

    let web: WKWebView
    let files = SessionFiles()
    private(set) weak var owner: ArticleView.Coordinator?
    /// The page ran its script and can render.
    private var ready = false

    override init() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(files, forURLScheme: "takes")
        web = WKWebView(frame: .zero, configuration: config)
        super.init()
        // The page holds a weak link back: WKUserContentController keeps its handlers strongly.
        let relay = WeakRelay(self)
        for name in ArticleView.Coordinator.messages { config.userContentController.add(relay, name: name) }
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        web.allowsMagnification = true
        load()
    }

    private func load() {
        ready = false
        web.loadHTMLString(ArticlePage.html, baseURL: URL(string: "takes://session/"))
    }

    /// A new article view takes the page: it renders its own article at once, from the top.
    func adopt(_ c: ArticleView.Coordinator) {
        owner = c
        c.ready = ready
    }

    func release(_ c: ArticleView.Coordinator) {
        guard owner === c else { return }
        owner = nil
        web.removeFromSuperview()
        // Empty while it waits: the next article must not show this one first. The page's pending
        // timers go too: a late "change" from the empty page would save an empty article over
        // the next one. (Typing in the last 250 ms is lost, as it was when the page closed.)
        if ready {
            web.evaluateJavaScript("clearTimeout(typing); clearTimeout(heading); clearTimeout(selTimer); "
                                   + "takes.render([], \(ArticleHead(nil).json)); window.scrollTo(0, 0)")
        }
        if Self.idle.count < Self.keep, !Self.idle.contains(where: { $0 === self }) { Self.idle.append(self) }
    }

    func userContentController(_ ctl: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "ready" { ready = true }
        owner?.receive(message)
    }

    /// Links open in the browser, not in the preview.
    func webView(_ web: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let u = action.request.url {
            if u.scheme == "takes", let s = files.session {
                NSWorkspace.shared.open(s.appending(path: String(u.path.dropFirst())))
            } else { NSWorkspace.shared.open(u) }
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    /// The web process quit (memory pressure, a crash): load the page again, then render.
    func webViewWebContentProcessDidTerminate(_ web: WKWebView) {
        owner?.ready = false
        owner?.forget()
        load()
    }

    private final class WeakRelay: NSObject, WKScriptMessageHandler {
        weak var host: ArticlePageHost?
        init(_ h: ArticlePageHost) { host = h }
        func userContentController(_ ctl: WKUserContentController, didReceive message: WKScriptMessage) {
            host?.userContentController(ctl, didReceive: message)
        }
    }
}

/// takes://session/<path> serves a file of the session; takes://font/<name> a font of the app.
final class SessionFiles: NSObject, WKURLSchemeHandler {
    var session: URL?

    static var fontDir: URL? {
        if let r = Bundle.main.resourceURL?.appending(path: "Article"), FileManager.default.fileExists(atPath: r.path) { return r }
        // swift run and tests: the repo's copy.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "assets/article")
        return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
    }

    func webView(_ web: WKWebView, start task: WKURLSchemeTask) {
        guard let u = task.request.url else { return }
        let path = u.path.removingPercentEncoding ?? u.path
        let file: URL? = u.host == "font" ? Self.fontDir?.appending(path: (path as NSString).lastPathComponent)
            : session?.appending(path: String(path.drop(while: { $0 == "/" })))
        // Only files inside the session (or the font folder): no "../" out of it.
        guard let file, let base = (u.host == "font" ? Self.fontDir : session),
              file.standardizedFileURL.path.hasPrefix(base.standardizedFileURL.path),
              let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(URLResponse(url: u, mimeType: type, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ web: WKWebView, stop task: WKURLSchemeTask) {}
}



/// The page: the site's post layout (app/blog/[slug]/page.tsx) and its CSS, from globals.css,
/// the Tailwind reset it sits on, and the classes of each MDX component.
enum ArticlePage {
    static let html = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>\(css)</style></head>
    <body><main>
      <nav class="crumb">[~/]<span class="sep">/</span>[blog]<span class="slug"></span></nav>
      <header>
        <div class="catwrap"><div class="category"></div><div class="catmenu"></div></div>
        <h1 class="title"></h1>
        <p class="description"></p>
        <time class="date"></time>
      </header>
      <article class="prose"></article>
      <div class="share"><p>If this was useful, share it.</p><div><a>[Share on X]</a><a>[Share on LinkedIn]</a></div></div>
    </main>
    <script>\(js)</script></body></html>
    """

    static let css = #"""
    @import url("https://api.fontshare.com/v2/css?f[]=satoshi@400,500,700&display=swap");
    :root { --primary: #C75B2D; --text: #1a1a1a; --text-light: #666666; --bg: #ffffff; --surface: #f9f9f9;
            --gray: #8B8B8B; --border: #e5e7eb; --mono: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; }
    *, ::before, ::after { box-sizing: border-box; margin: 0; padding: 0; border: 0 solid; }
    html { -webkit-text-size-adjust: 100%; }
    body { background: var(--bg); color: var(--text); font-family: Satoshi, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
           font-size: 1.125rem; line-height: 1.6; -webkit-font-smoothing: antialiased; }
    img, video, svg { display: block; max-width: 100%; height: auto; }
    svg { display: inline; }
    a { color: var(--primary); text-decoration: none; cursor: pointer; }
    ol, ul { list-style: none; }
    table { border-collapse: collapse; }
    pre, code { font-family: var(--mono); }
    summary { display: list-item; }
    main { max-width: 42rem; margin: 0 auto; padding: 6rem 1.5rem 4rem; }
    .crumb { font-family: var(--mono); font-size: .75rem; line-height: 1rem; color: var(--gray); margin-bottom: 1.5rem; }
    .crumb .sep, .crumb .slug .sep { margin: 0 .25rem; }
    .crumb .slug b { font-weight: 400; color: var(--text-light); }
    header { margin-bottom: 3rem; }
    .category { font-family: var(--mono); font-size: .75rem; line-height: 1rem; color: var(--gray); margin-bottom: .75rem; }
    .title { font-size: 2.25rem; line-height: 2.5rem; font-weight: 600; margin-bottom: 1rem; }
    .title.empty, .description.empty { color: #c4c4c4; }
    .description { font-size: 1.25rem; line-height: 1.75rem; color: var(--text-light); margin-bottom: 1rem; }
    .date { display: block; font-size: .875rem; line-height: 1.25rem; color: var(--text-light); }
    .share { margin-top: 4rem; padding-top: 2rem; border-top: 1px solid var(--border); }
    .share p { font-size: .875rem; line-height: 1.25rem; color: var(--text-light); margin-bottom: .75rem; }
    .share div { display: flex; gap: 1rem; }
    .share a { font-size: .875rem; line-height: 1.25rem; font-weight: 500; }

    .prose { max-width: 680px; }
    .prose h1, .prose h2, .prose h3 { font-weight: 600; line-height: 1.3; margin-top: 2rem; margin-bottom: 1rem; }
    .prose h1 { font-size: 2.5rem; } .prose h2 { font-size: 1.75rem; } .prose h3 { font-size: 1.25rem; }
    .prose h4, .prose h5, .prose h6 { font-size: inherit; font-weight: inherit; }
    .prose p { margin-bottom: 1.5rem; }
    .prose ul, .prose ol { margin-bottom: 1.5rem; padding-left: 1.5rem; }
    .prose ul { list-style-type: disc; } .prose ol { list-style-type: decimal; }
    .prose li { margin-bottom: .5rem; }
    .prose li > ul, .prose li > ol { margin-top: .5rem; margin-bottom: 0; }
    .prose pre { background: var(--surface); border: 1px solid #e5e5e5; border-radius: .5rem; padding: 1rem; overflow-x: auto; margin-bottom: 1.5rem; }
    .prose code { font-family: var(--mono); font-size: .875em; }
    .prose blockquote { border-left: 3px solid var(--primary); padding-left: 1rem; margin-left: 0; font-style: italic; color: var(--text-light); }
    .prose a { color: var(--primary); text-decoration: none; }
    .prose hr { border-top: 1px solid var(--border); margin: 2rem 0; }
    .prose strong { font-weight: 700; }

    .callout { margin: 1.5rem 0; border-radius: .5rem; background: rgba(199, 91, 45, .05); padding: 1rem; display: flex; align-items: flex-start; gap: .75rem; }
    .callout-icon { font-family: var(--mono); font-size: .875rem; line-height: 1.25rem; color: var(--primary); flex-shrink: 0; }
    .callout-body { flex: 1; }
    .callout-label { font-family: var(--mono); font-size: .75rem; line-height: 1rem; text-transform: uppercase; letter-spacing: .025em; color: var(--primary); display: block; margin-bottom: .25rem; }
    .callout-text > :last-child { margin-bottom: 0; }

    .terminal { margin: 1.5rem 0; border-radius: .5rem; background: #101828; overflow: hidden; }
    .terminal-bar { display: flex; align-items: center; justify-content: space-between; border-bottom: 1px solid #364153; padding: .5rem 1rem; }
    .dots { display: flex; gap: .375rem; } .dots i { width: .75rem; height: .75rem; border-radius: 9999px; opacity: .75; display: block; }
    .dots .r { background: #fb2c36; } .dots .y { background: #f0b100; } .dots .g { background: #00c950; }
    .copy { color: #99a1af; padding: .375rem; border-radius: .25rem; display: inline-flex; }
    .terminal-body { padding: 1rem; }
    .prose .terminal pre, .terminal pre { font-family: var(--mono); font-size: .875rem; line-height: 1.625; white-space: pre-wrap;
        background: transparent; border: none; padding: 0; margin: 0; color: #f3f4f6; }
    .terminal .prompt { color: #4ade80; }

    .tip { position: relative; display: inline-block; }
    .tip-word { cursor: help; border-bottom: 1px dotted #9ca3af; }
    .tip-bubble { visibility: hidden; opacity: 0; position: absolute; bottom: 100%; left: 50%; z-index: 50; margin-bottom: .5rem; width: 16rem;
        transform: translateX(-50%); border-radius: .5rem; background: #101828; padding: .5rem .75rem; font-size: .875rem; line-height: 1.25rem;
        color: #fff; box-shadow: 0 10px 15px -3px rgba(0,0,0,.1); transition: opacity .15s; font-style: normal; }
    .tip:hover .tip-bubble { visibility: visible; opacity: 1; }

    .tweet { margin: 1.5rem 0; border-radius: .5rem; border: 1px solid var(--border); background: var(--surface); padding: 1rem; }
    .tweet-label { font-family: var(--mono); font-size: .75rem; line-height: 1rem; text-transform: uppercase; letter-spacing: .025em; color: var(--gray); margin: 0 !important; }
    .tweet a { margin-top: .5rem; display: inline-flex; font-size: .875rem; line-height: 1.25rem; font-weight: 500; }

    .filetree { margin: 1.5rem 0; border-radius: .5rem; border: 1px solid var(--border); background: var(--surface); padding: 1rem; }
    .filetree pre { font-size: .875rem; line-height: 1.625; color: var(--text); }

    .ascii { margin: 1.5rem 0; } .ascii > div { overflow-x: auto; border-radius: .5rem; border: 1px solid var(--border); background: var(--surface); padding: 1rem; }
    .prose .ascii pre { font-size: .75rem; line-height: 1.625; text-align: center; background: none; border: 0; padding: 0; margin: 0; }
    figcaption { margin-top: .5rem; text-align: center; font-size: .875rem; line-height: 1.25rem; color: var(--text-light); }

    .promptbox { margin: 1.5rem 0; border-radius: .5rem; border: 1px solid var(--border); background: var(--surface); overflow: hidden; }
    .promptbox-bar { display: flex; align-items: center; justify-content: space-between; border-bottom: 1px solid var(--border); padding: .5rem 1rem; }
    .prompt-title { font-size: .875rem; line-height: 1.25rem; font-weight: 500; color: var(--text-light); }
    .prompt-tag { font-family: var(--mono); font-size: .75rem; color: var(--gray); }
    .promptbox .copy { color: var(--gray); }
    .promptbox-body { padding: 1rem; font-family: var(--mono); font-size: .875rem; line-height: 1.625; white-space: pre-wrap; }

    .tldr { margin: 1.5rem 0; } .tldr details { border-radius: .5rem; background: var(--surface); }
    .tldr summary { display: flex; cursor: pointer; align-items: center; gap: .5rem; padding: .75rem 1rem; font-family: var(--mono);
        font-size: .875rem; line-height: 1.25rem; color: var(--gray); list-style: none; }
    .tldr summary::-webkit-details-marker { display: none; }
    .tldr-sign { color: var(--primary); } .tldr-sign::before { content: "[+]"; } .tldr details[open] .tldr-sign::before { content: "[-]"; }
    .tldr-body { border-top: 1px solid var(--border); padding: .75rem 1rem; min-height: 4rem; }
    .tldr-body ul { list-style: disc; padding-left: 1.25rem; } .tldr-body ol { list-style: decimal; padding-left: 1.25rem; }
    .tldr-body li { margin-bottom: .25rem; } .tldr-body > :last-child { margin-bottom: 0; }

    .collapse { margin: 1.5rem 0; border-radius: .5rem; border: 1px solid var(--border); background: var(--surface); }
    .collapse summary { cursor: pointer; padding: .75rem 1rem; font-weight: 500; }
    .collapse > div { border-top: 1px solid var(--border); padding: .75rem 1rem; } .collapse > div > :last-child { margin-bottom: 0; }

    .steps { margin: 1.5rem 0; counter-reset: step; } .steps > * + * { margin-top: 1rem; }
    .step { display: flex; gap: 1rem; counter-increment: step; }
    .step-n { display: flex; height: 1.75rem; width: 1.75rem; flex-shrink: 0; align-items: center; justify-content: center; border-radius: 9999px;
        background: var(--primary); font-size: .875rem; font-weight: 500; color: #fff; }
    .step-n::before { content: counter(step); }
    .step > div { padding-top: .125rem; } .step-title { font-weight: 500; } .step-text { margin-top: .25rem; color: var(--text-light); }
    .step-text > :last-child { margin-bottom: 0; }

    .flow { margin: 2rem 0; } .flow-col { display: flex; flex-direction: column; align-items: center; }
    .flow-box { border: 2px solid var(--primary); background: rgba(199, 91, 45, .05); color: var(--primary); padding: .75rem 1.5rem; text-align: center;
        min-width: 120px; max-width: 180px; border-radius: .5rem; font-family: var(--mono); font-size: .875rem; line-height: 1.25rem; font-weight: 500; }
    .flow-box.no { border-color: #d1d5db; background: #f9fafb; color: #4a5565; }
    .flow-arrow { display: flex; flex-direction: column; align-items: center; } .flow-arrow i { width: 1px; height: 1rem; background: #d1d5db; display: block; }
    .flow-arrow span { font-size: 10px; line-height: 1; color: #d1d5db; }
    .flow-branches { display: flex; gap: 2rem; max-width: 28rem; margin-top: .5rem; }
    .flow-branches > div { display: flex; flex-direction: column; align-items: center; gap: .25rem; }
    .flow-label { font-size: .75rem; color: #6a7282; } .flow-loop { font-size: .75rem; color: #99a1af; }
    .flow figcaption { margin-top: 1rem; }

    .harmonograph { margin: 2rem 0; } .harmonograph > div { overflow: hidden; border-radius: .75rem; border: 1px solid #1e2939; background: #0E1117;
        display: flex; align-items: center; justify-content: center; } .harmonograph span { font-family: var(--mono); font-size: .75rem; color: #4a5565; }
    .harmonograph figcaption { color: var(--gray); }
    .wide { margin: 2rem 0; }
    .chart { margin: 1.5rem 0; border-radius: .5rem; background: var(--surface); display: flex; align-items: center; justify-content: center; }
    .chart span { font-family: var(--mono); font-size: .875rem; color: var(--gray); }

    /* Writing in the page: no frame, a caret, placeholders, components that open as their source. */
    [contenteditable]:focus { outline: none; }
    article { caret-color: var(--primary); min-height: 40vh; }
    .title:empty::before { content: "Title"; color: #c4c4c4; }
    .description:empty::before { content: "One line under the title"; color: #c4c4c4; }
    .category { cursor: pointer; display: inline-block; } .category:hover { color: var(--primary); }
    .category.empty { color: #c4c4c4; }
    .catwrap { position: relative; margin-bottom: .75rem; } .catwrap .category { margin-bottom: 0; }
    .catmenu { display: none; position: absolute; top: 1.4rem; left: -.5rem; z-index: 60; flex-direction: column; padding: .25rem;
        background: #fff; border: 1px solid var(--border); border-radius: .5rem; box-shadow: 0 8px 24px rgba(0,0,0,.08); }
    .catmenu button { font: inherit; font-family: var(--mono); font-size: .75rem; text-align: left; color: var(--text-light);
        background: none; padding: .3rem .6rem; border-radius: .3rem; cursor: pointer; }
    .catmenu button:hover { background: var(--surface); } .catmenu button.on { color: var(--primary); }
    .atom { border-radius: .5rem; cursor: default; transition: box-shadow .15s; }
    .atom:hover { box-shadow: 0 0 0 2px rgba(199, 91, 45, .18); }
    .prose pre.src { font-size: .8125rem; line-height: 1.6; white-space: pre-wrap; background: #fffaf7;
        border: 1.5px solid rgba(199, 91, 45, .45); color: var(--text); }
    mark.c { background: rgba(199, 91, 45, .16); color: inherit; border-bottom: 1.5px solid #C75B2D; cursor: pointer; }
    mark.c.flash { background: rgba(199, 91, 45, .38); transition: background .6s; }
    ::selection { background: #bcd6fa; }
    """#

    static let js = #"""
    const $ = s => document.querySelector(s);
    const post = (name, v) => window.webkit.messageHandlers[name].postMessage(v);
    const art = () => $('article');
    // Each block keeps the markdown it came from and its page as rendered. Only a block whose page
    // changed is written back as markdown, so components and untouched text keep their source.
    const src = new WeakMap();
    const TEXT = new Set(['P', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'UL', 'OL', 'BLOCKQUOTE', 'PRE', 'HR']);
    const clean = el => {
      const c = el.cloneNode(true);
      c.querySelectorAll('mark.c').forEach(m => m.replaceWith(...m.childNodes));
      c.normalize();
      return c.innerHTML;
    };
    const CATS = ['tech', 'life', 'business'];
    const takes = {
      render(blocks, head) {
        const a = art(); a.innerHTML = '';
        for (const b of blocks) {
          const t = document.createElement('template'); t.innerHTML = b.html.trim();
          const kids = [...t.content.childNodes].filter(n => n.nodeType === 1 || n.textContent.trim());
          let el;
          if (kids.length === 1 && kids[0].nodeType === 1 && TEXT.has(kids[0].tagName)) el = kids[0];
          else { el = document.createElement('div'); el.className = 'atom'; el.append(...t.content.childNodes); }
          a.append(el);
          src.set(el, { md: b.md, html: clean(el) });
        }
        if (!blocks.length) a.innerHTML = '<p><br></p>';
        a.querySelectorAll('.atom, .tip').forEach(e => e.contentEditable = 'false');
        takes.head(head, true);
        takes.quotes && takes.mark(takes.quotes);
      },
      // The head; a field being typed in keeps what it has.
      head(h, force) {
        const t = $('.title'), d = $('.description');
        if (force || document.activeElement !== t) t.textContent = h.title || '';
        if (force || document.activeElement !== d) d.textContent = h.description || '';
        const c = $('.category'); c.textContent = h.category ? '/' + h.category : '/category'; c.classList.toggle('empty', !h.category);
        takes.cat = h.category || '';
        $('.date').textContent = h.date || '';
        $('.slug').innerHTML = h.slug ? '<span class="sep">/</span><b></b>' : '';
        if (h.slug) $('.slug b').textContent = h.slug;
      },
      markdown() {
        const out = [];
        for (const el of art().children) {
          const s = src.get(el);
          if (s && clean(el) === s.html) { out.push(s.md); continue; }
          const m = block(el);
          if (m.trim()) out.push(m);
        }
        return out.join('\n\n');
      },
      // A component from the Components menu, after the block with the caret (or at the end).
      insert(md) {
        const el = document.createElement('div'); el.className = 'atom'; el.contentEditable = 'false';
        src.set(el, { md, html: '' });
        const b = current(); b ? b.after(el) : art().append(el);
        post('commit', takes.markdown());
      },
      // Comment quotes: marked where the text shows them, in one text node or across a few.
      mark(quotes) {
        takes.quotes = quotes;
        document.querySelectorAll('mark.c').forEach(m => { m.replaceWith(...m.childNodes); });
        $('main').normalize();
        for (const q of quotes) if (q && q.trim()) takes.wrap(q.trim());
      },
      wrap(q) {
        const walker = document.createTreeWalker($('main'), NodeFilter.SHOW_TEXT);
        const nodes = []; let text = '';
        while (walker.nextNode()) { nodes.push([walker.currentNode, text.length]); text += walker.currentNode.data; }
        let at = text.indexOf(q);
        if (at < 0) {
          // Markdown marks (** _ `) are gone in the page: look for the words alone.
          const plain = q.replace(/[*_`#>\[\]]|\(([^)]*)\)/g, '').trim();
          at = plain ? text.indexOf(plain) : -1;
          if (at < 0) return; q = plain;
        }
        const end = at + q.length;
        for (const [node, start] of nodes) {
          const s = Math.max(at, start), e = Math.min(end, start + node.data.length);
          if (s >= e) continue;
          const r = document.createRange(); r.setStart(node, s - start); r.setEnd(node, e - start);
          const m = document.createElement('mark'); m.className = 'c'; m.dataset.q = q;
          try { r.surroundContents(m); } catch (_) {}
        }
      },
      reveal(q) {
        const m = [...document.querySelectorAll('mark.c')].find(m => m.dataset.q === q.trim() || q.includes(m.dataset.q));
        if (!m) return;
        m.scrollIntoView({ behavior: 'smooth', block: 'center' });
        m.classList.add('flash'); setTimeout(() => m.classList.remove('flash'), 900);
      }
    };

    // MARK: page to markdown
    const back = u => u.replace(/^takes:\/\/session\//, '').replace(/^https:\/\/example\.com\//, '/');
    const around = (m, s) => { const c = s.trim(); return c ? s.match(/^\s*/)[0] + m + c + m + s.match(/\s*$/)[0] : s; };
    function inline(el) { return [...el.childNodes].map(node).join('').replace(/ /g, ' '); }
    function node(n) {
      if (n.nodeType === 3) return n.data;
      if (n.nodeType !== 1) return '';
      const t = n.tagName;
      if (n.classList.contains('tip')) {
        const tip = n.querySelector('.tip-bubble')?.textContent || '', word = n.querySelector('.tip-word')?.textContent || '';
        return `<Tooltip text="${tip}">${word}</Tooltip>`;
      }
      if (t === 'STRONG' || t === 'B') return around('**', inline(n));
      if (t === 'EM' || t === 'I') return around('_', inline(n));
      if (t === 'CODE') return '`' + n.textContent + '`';
      if (t === 'A') return `[${inline(n)}](${back(n.getAttribute('href') || '')})`;
      if (t === 'IMG') return `![${n.getAttribute('alt') || ''}](${back(n.getAttribute('src') || '')})`;
      if (t === 'BR') return n.nextSibling ? '<br />' : '';
      if (TEXT.has(t) || t === 'DIV') return '\n\n' + block(n) + '\n\n';
      return inline(n);
    }
    function block(el) {
      const t = el.tagName;
      if (el.classList.contains('atom')) return src.get(el)?.md || '';
      if (el.classList.contains('src')) return el.innerText.replace(/\n+$/, '');
      if (/^H[1-6]$/.test(t)) return '#'.repeat(+t[1]) + ' ' + inline(el).trim();
      if (t === 'UL' || t === 'OL') return list(el, '');
      if (t === 'BLOCKQUOTE') {
        const inner = [...el.children].some(c => TEXT.has(c.tagName)) ? [...el.children].map(block).filter(Boolean).join('\n\n') : inline(el).trim();
        return inner.split('\n').map(l => l ? '> ' + l : '>').join('\n');
      }
      if (t === 'PRE') {
        const lang = (el.querySelector('code')?.className.match(/language-(\S+)/) || [])[1] || '';
        return '```' + lang + '\n' + el.innerText.replace(/\n+$/, '') + '\n```';
      }
      if (t === 'HR') return '---';
      return inline(el).trim().replace(/\n{3,}/g, '\n\n');
    }
    function list(el, indent) {
      const ordered = el.tagName === 'OL'; let n = 1; const out = [];
      for (const li of el.children) {
        if (li.tagName !== 'LI') continue;
        const mark = ordered ? (n++) + '. ' : '- ';
        const text = [], nested = [];
        for (const c of li.childNodes) {
          if (c.nodeType === 1 && (c.tagName === 'UL' || c.tagName === 'OL')) nested.push(list(c, indent + ' '.repeat(mark.length)));
          else if (c.nodeType === 1 && c.tagName === 'P') text.push(inline(c).trim());
          else text.push(node(c));
        }
        out.push(indent + mark + text.join('').replace(/\s*\n\s*/g, ' ').trim(), ...nested);
      }
      return out.join('\n');
    }

    // MARK: typing
    function current() {
      const s = getSelection(); if (!s.rangeCount) return null;
      let el = s.anchorNode;
      while (el && el.parentNode !== art()) el = el.parentNode;
      return el && el.nodeType === 1 ? el : null;
    }
    // "## ", "- ", "1. " and "> " at the start of a paragraph make it a heading, a list or a quote.
    function shortcut() {
      const el = current();
      if (!el || (el.tagName !== 'P' && el.tagName !== 'DIV') || el.classList.contains('atom')) return;
      const m = el.textContent.match(/^(#{1,3}|[-*]|1[.)]|>)[\s ]/);
      if (!m) return;
      let cut = m[0].length;
      const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
      while (cut > 0 && w.nextNode()) { const k = Math.min(cut, w.currentNode.data.length); w.currentNode.deleteData(0, k); cut -= k; }
      const k = m[1];
      let outer, inner;
      if (k[0] === '#') { outer = inner = document.createElement('h' + k.length); }
      else if (k === '>') { outer = document.createElement('blockquote'); inner = document.createElement('p'); outer.append(inner); }
      else { outer = document.createElement(k[0] === '1' ? 'ol' : 'ul'); inner = document.createElement('li'); outer.append(inner); }
      inner.append(...el.childNodes);
      if (!inner.textContent) inner.innerHTML = '<br>';
      el.replaceWith(outer);
      const r = document.createRange(); r.setStart(inner, 0); r.collapse(true);
      const s = getSelection(); s.removeAllRanges(); s.addRange(r);
    }
    let typing;
    const changed = () => { clearTimeout(typing); typing = setTimeout(() => post('change', takes.markdown()), 250); };
    let heading;
    const headChanged = () => {
      clearTimeout(heading);
      heading = setTimeout(() => post('head', { title: $('.title').textContent.trim(), description: $('.description').textContent.trim() }), 300);
    };
    function setup() {
      document.execCommand('defaultParagraphSeparator', false, 'p');
      const a = art();
      a.contentEditable = 'true';
      a.addEventListener('input', () => { shortcut(); changed(); });
      for (const f of ['.title', '.description']) {
        const e = $(f);
        e.contentEditable = 'plaintext-only';
        e.addEventListener('input', headChanged);
        e.addEventListener('keydown', ev => {
          if (ev.key !== 'Enter') return;
          ev.preventDefault();
          (f === '.title' ? $('.description') : art()).focus();
        });
      }
      // Pasted text comes in plain: the page's own styles, never another site's.
      a.addEventListener('paste', ev => {
        const text = ev.clipboardData.getData('text/plain'); if (!text) return;
        ev.preventDefault();
        const parts = text.replace(/\r\n/g, '\n').split(/\n{2,}/);
        if (parts.length === 1) document.execCommand('insertText', false, text);
        else {
          const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
          document.execCommand('insertHTML', false, parts.map(p => '<p>' + esc(p).replace(/\n/g, '<br>') + '</p>').join(''));
        }
      });
      // A component opens as its source; leaving it renders it again.
      a.addEventListener('dblclick', ev => {
        const atom = ev.target.closest('.atom'); if (!atom) return;
        const ed = document.createElement('pre'); ed.className = 'src'; ed.contentEditable = 'plaintext-only';
        ed.textContent = src.get(atom)?.md || '';
        atom.replaceWith(ed); ed.focus();
      });
      a.addEventListener('focusout', ev => {
        if (ev.target.classList?.contains('src')) setTimeout(() => post('commit', takes.markdown()), 0);
      }, true);
      $('.category').addEventListener('click', ev => {
        const menu = $('.catmenu');
        if (menu.style.display === 'flex') { menu.style.display = 'none'; return; }
        menu.innerHTML = '';
        for (const c of [...CATS, '']) {
          const b = document.createElement('button');
          b.textContent = c ? '/' + c : 'none';
          b.classList.toggle('on', c === takes.cat);
          b.onclick = e => { e.stopPropagation(); menu.style.display = 'none'; post('cat', c); };
          menu.append(b);
        }
        menu.style.display = 'flex';
        ev.stopPropagation();
      });
      document.addEventListener('click', () => { $('.catmenu').style.display = 'none'; });
    }
    let selTimer;
    document.addEventListener('selectionchange', () => {
      clearTimeout(selTimer);
      selTimer = setTimeout(() => post('sel', String(window.getSelection()).trim()), 120);
    });
    document.addEventListener('click', e => {
      const m = e.target.closest('mark.c');
      if (m && !String(window.getSelection()).trim()) post('pick', m.dataset.q);
      const a = e.target.closest('a'); if (a && !e.metaKey) e.preventDefault();
    });
    setup();
    post('ready', '');
    """#
}

// MARK: - Writing

enum ArticleLook {
    /// The blog's accent, --color-primary on your blog.
    static let orange = Color(red: 0xC7 / 255, green: 0x5B / 255, blue: 0x2D / 255)
}

/// The blog's components, each with how to write it. A click puts it in the page; a double
/// click on it there opens its source.
struct ArticleComponentsHelp: View {
    let pick: (String) -> Void
    static let items: [(String, String)] = [
        ("Callout", "<Callout type=\"tip\">\nText. type is tip, warning or note.\n</Callout>"),
        ("Terminal", "<Terminal>\n$ mosh devbox\n$ claude\n</Terminal>"),
        ("TL;DR", "<TLDR>\n- The first point.\n- The second point.\n</TLDR>"),
        ("Prompt", "<Prompt title=\"/review\">\nThe prompt, as you type it.\n</Prompt>"),
        ("Flowchart", "<Flowchart steps={[\"write the change\", { decision: \"tests pass?\", yes: \"ship\", no: \"fix\" }, \"shipped\"]} caption=\"One PR, every time.\" />"),
        ("Steps", "<Steps>\n<Step title=\"Install\">\nWhat to do.\n</Step>\n<Step title=\"Run\">\nWhat happens.\n</Step>\n</Steps>"),
        ("File tree", "<FileTree>{`~/.claude/skills/\n├── review/\n└── ship/`}</FileTree>"),
        ("Tooltip", "<Tooltip text=\"What the word means.\">word</Tooltip>"),
        ("X post", "<Tweet id=\"20\" />"),
        ("Collapse", "<Collapse title=\"The details\">\nHidden until opened.\n</Collapse>"),
        ("Picture", "![What it shows](thumbnails/cover-v1.png)"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Components of the blog").font(Theme.sans(12, .semibold)).foregroundStyle(Theme.muted).padding(.bottom, 6)
            ForEach(Self.items, id: \.0) { name, code in
                Button { pick(code) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name).font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.ink)
                        Text(code).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.faint).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Put it in after the paragraph with the cursor")
            }
            Text("Double-click a component in the page to change its source. Pictures with a path in the session (thumbnails/, stills/, assets/) show here; /images/… comes from the live site.")
                .font(Theme.sans(11)).foregroundStyle(Theme.faint).padding(.top, 6)
        }
        .padding(14).frame(width: 340)
    }
}
