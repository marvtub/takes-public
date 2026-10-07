import Foundation
import Testing
@testable import Takes

// 2026-10-04: the blog article (posts/article.md), rendered as your blog renders a post.

struct ArticleTests {
    @Test func platformFiles() {
        #expect(PostPlatform.article.rel == "posts/article.md")
        #expect(PostPlatform.of(rel: "posts/article.md") == .article)
        #expect(PostPlatform.of(rel: "posts/article/variants/short.md") == .article)
    }

    @Test func markdownBlocks() {
        let h = Article.html("## Why\n\nI **ship** with *care* and `code`.\nSame paragraph.\n\n> A quote\n\n- one\n- two\n\n1. first\n2. second\n\n```bash\necho <hi>\n```\n\n---")
        #expect(h.contains("<h2>Why</h2>"))
        #expect(h.contains("<p>I <strong>ship</strong> with <em>care</em> and <code>code</code>.\nSame paragraph.</p>"))
        #expect(h.contains("<blockquote><p>A quote</p></blockquote>"))
        #expect(h.contains("<ul><li>one</li><li>two</li></ul>"))
        #expect(h.contains("<ol><li>first</li><li>second</li></ol>"))
        #expect(h.contains("<pre><code class=\"language-bash\">echo &lt;hi&gt;</code></pre>"))
        #expect(h.contains("<hr>"))
    }

    @Test func nestedListsAndLinks() {
        let h = Article.html("- top\n  - inner\n- next [site](https://x.com) ![pic](stills/a.jpg) ![s](/images/b.webp)")
        #expect(h.contains("<li>top\n<ul><li>inner</li></ul></li>"))
        #expect(h.contains("<a href=\"https://x.com\">site</a>"))
        #expect(h.contains("<img src=\"stills/a.jpg\""))
        #expect(h.contains("src=\"https://example.com/images/b.webp\""))
    }

    @Test func componentsFromRealPosts() {
        let callout = Article.html("<Callout type=\"tip\">Mosh is the **unsung** piece here.</Callout>")
        #expect(callout.contains("class=\"callout\"") && callout.contains("[→]") && callout.contains(">tip<"))
        #expect(callout.contains("<strong>unsung</strong>"))

        let term = Article.html("<Terminal title=\"laptop\">\n$ mosh devbox\n$ claude\n</Terminal>\n\nAfter.")
        #expect(term.contains("<span class=\"prompt\">&gt;</span> $ mosh devbox\n$ claude</pre>"))
        #expect(term.contains("<p>After.</p>"))

        let tldr = Article.html("<TLDR>\n- I journal by talking.\n- It works.\n</TLDR>")
        #expect(tldr.contains("<aside class=\"tldr\">") && tldr.contains("<li>I journal by talking.</li>"))

        let tree = Article.html("<FileTree>{`~/.claude/skills/\n├── pre-pr-review/`}</FileTree>")
        #expect(tree.contains("<pre>~/.claude/skills/\n├── pre-pr-review/</pre>"))

        let tweet = Article.html("<Tweet id=\"20\" />")
        #expect(tweet.contains("https://x.com/i/status/20"))

        let video = Article.html("<Video src=\"thumbnails/launch-v1.mp4\" poster=\"thumbnails/launch-poster-v1.jpg\" title=\"Launch\" />")
        #expect(video.contains("<video src=\"thumbnails/launch-v1.mp4\" poster=\"thumbnails/launch-poster-v1.jpg\" controls"))

        let tip = Article.html("Use <Tooltip text=\"Parallel checkouts\">worktrees</Tooltip> daily.")
        #expect(tip.contains("<span class=\"tip-word\">worktrees</span><span class=\"tip-bubble\" role=\"tooltip\">Parallel checkouts</span>"))
    }

    @Test func flowchartAndSteps() {
        let flow = Article.html("<Flowchart steps={[\"write the change\", { decision: \"tests pass?\", yes: \"ship\", no: \"fix\" }, \"shipped\"]} caption=\"One PR.\" />")
        #expect(flow.contains("<div class=\"flow-box\">write the change</div>"))
        #expect(flow.contains("<div class=\"flow-box no\">fix</div>"))
        #expect(flow.contains("<figcaption>One PR.</figcaption>"))

        let steps = Article.html("<Steps>\n<Step title=\"Install\">\nGet it.\n</Step>\n<Step title=\"Run\">\nGo.\n</Step>\n</Steps>")
        #expect(steps.components(separatedBy: "class=\"step\"").count == 3)
        #expect(steps.contains("<div class=\"step-title\">Run</div>"))

        let multi = Article.html("<Flowchart\n  steps={[\"a\", \"b\"]}\n  caption=\"Two lines\"\n/>")
        #expect(multi.contains(">a</div>") && multi.contains("Two lines"))
    }

    @Test func headSlugWordsAndMinutes() {
        #expect(Article.slug("How I Ship Without Reading Code!") == "how-i-ship-without-reading-code")
        let text = Array(repeating: "word", count: 401).joined(separator: " ")
        #expect(Article.words(text) == 401)
        #expect(Article.minutes(text) == 3)
        var c = PostFile.Content(text: "Body\n")
        c.title = "Rest Is an Input"
        c.meta["category"] = "Life"
        let head = ArticleHead(c)
        #expect(head.slug == "rest-is-an-input")
        #expect(head.json.contains("\"category\":\"life\""))
    }

    @Test func expressionsAndRawHTML() {
        let h = Article.html("<video src=\"edits/a-v2.mp4\" controls></video>\n\nSay {\"> \"} here.")
        #expect(h.contains("<video src=\"edits/a-v2.mp4\" controls></video>"))
        #expect(h.contains("<p>Say &gt;  here.</p>"))
    }

    /// One of everything the blog has, for the snapshot.
    static let sample = """
    I stopped reading every line my agent writes. Not because I trust it blindly, but because the checks read it for me. Here is the loop, and the three pieces that make it safe.

    ## The loop

    Every change goes through the same path. I write the request, the agent writes the code in one of my <Tooltip text="A git feature that gives you parallel checkouts of one repo.">worktrees</Tooltip>, and **nothing merges** until the review passes.

    <Flowchart steps={["write the change", "/pre-pr-review", { decision: "all green?", yes: "open the PR", no: "fix" }, "shipped"]} caption="One PR, every time." />

    > The point is not speed. The point is that I can stop looking.

    <Callout type="tip">
    Start with one repo. The rules grow from the mistakes you see there.
    </Callout>

    ### What runs on the box

    <Terminal title="laptop">
    $ mosh devbox
    $ dev personal-website
    $ claude
    </Terminal>

    The skills live in one folder:

    <FileTree>{`~/.claude/skills/
    ├── pre-pr-review/    # reads the diff
    └── ship/             # merges when green`}</FileTree>

    1. Write the change.
    2. Run `/pre-pr-review`.
    3. Ship it.

    <Prompt title="/prc draft comment">
    curious why we read the flag here instead of at startup?
    </Prompt>

    <TLDR>
    - The agent writes, the checks read.
    - One loop for every change.
    - Start small and let the rules grow.
    </TLDR>
    """
}
