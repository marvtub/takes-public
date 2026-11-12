import AppKit
import CoreText
import Testing
@testable import Takes

@MainActor
struct MarkdownReaderTests {
    static let sample = """
    # Target list

    Followers are from **2026-10-02**. See [the guide](comment-style-guide.md).

    ## Peers

    | Name | Followers | Your angle |
    |---|---|---|
    | [Rachel Woods](https://www.linkedin.com/in/woodsrach/) | 47K | Peer talk, `a|b` |
    | Fivos Aresti | 37K | Real workflow examples. |

    - One
      - Two
    1. First

    > A quote

    ---
    """

    /// Headings, tables and links read as text, without their marks; links still go somewhere.
    @Test func readsWithoutTheMarks() {
        let s = MarkdownText.attributed(Self.sample)
        let text = s.string
        #expect(text.contains("Target list\n"))
        #expect(!text.contains("#"))
        #expect(!text.contains("**"))
        #expect(!text.contains("|---"))
        #expect(!text.contains("](https"))
        #expect(text.contains("Rachel Woods\n47K\nPeer talk, a|b\n"))
        let r = (text as NSString).range(of: "Rachel Woods")
        #expect(s.attribute(.link, at: r.location, effectiveRange: nil) as? URL == URL(string: "https://www.linkedin.com/in/woodsrach/"))
        let cell = s.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle
        #expect((cell?.textBlocks.first as? NSTextTableBlock)?.table.numberOfColumns == 3)
        #expect(text.contains("•\tOne"))
        #expect(text.contains("1.\tFirst"))
    }

    /// The target list: a LinkedIn name in the first column gets a round face before it (initials
    /// when no photo is saved); other columns and other links stay plain.
    @Test func targetListFaces() {
        let md = "| Name | Link |\n|---|---|\n| [Rachel Woods](https://www.linkedin.com/in/woodsrach/) | [x](https://www.linkedin.com/in/x/) |\n| [Doc](https://example.com) | a |\n"
        let empty = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let s = MarkdownText.attributed(md, faces: empty)
        let text = s.string as NSString
        let r = text.range(of: "Rachel Woods")
        #expect(r.location >= 2 && s.attribute(.attachment, at: r.location - 2, effectiveRange: nil) is NSTextAttachment)
        #expect(text.components(separatedBy: "\u{FFFC}").count == 2)
        #expect(MarkdownText.attributed(md).string.contains("\u{FFFC}") == false)
        #expect(MarkdownText.handle(URL(string: "https://www.linkedin.com/in/Some-Person/")!) == "some-person")
        #expect(MarkdownText.handle(URL(string: "https://www.linkedin.com/company/x/")!) == nil)
    }

    @Test func tableCells() {
        #expect(MarkdownText.attributed("| a | `x|y` | c \\| d |\n|---|---|---|\n").string == "a\nx|y\nc | d\n\n")
    }

    /// A quote made in Edit mode finds its text in Read mode.
    @Test func editorQuotesFindTheirText() {
        #expect(MarkdownReader.plain("[Rachel Woods](https://x.com) | **47K**") == "Rachel Woods | 47K")
    }

    /// Off by default: `TAKES_SNAPSHOT=/dir [TAKES_MD=file.md] ./test.sh --filter MarkdownReader`.
    @Test func snapshot() throws {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] else { return }
        let fonts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../assets/fonts")
        for f in (try? FileManager.default.contentsOfDirectory(at: fonts, includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
        let md = ProcessInfo.processInfo.environment["TAKES_MD"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? Self.sample
        for (name, look) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try #require(NSAppearance(named: look))
            NSAppearance.current = appearance
            do {
                let tv = NSTextView(usingTextLayoutManager: false)
                tv.appearance = appearance
                tv.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
                tv.textContainerInset = NSSize(width: 40, height: 32)
                tv.isVerticallyResizable = true
                tv.backgroundColor = Theme.paperNS
                let faces = ProcessInfo.processInfo.environment["TAKES_FACES"].map { URL(fileURLWithPath: $0) }
                tv.textStorage?.setAttributedString(MarkdownText.attributed(md, size: 14.5, faces: faces))
                tv.layoutManager?.ensureLayout(for: tv.textContainer!)
                tv.sizeToFit()
                let h = min(2400, (tv.layoutManager?.usedRect(for: tv.textContainer!).height ?? 400) + 64)
                tv.frame.size.height = h
                let rep = try #require(tv.bitmapImageRepForCachingDisplay(in: tv.bounds))
                tv.cacheDisplay(in: tv.bounds, to: rep)
                let data = try #require(rep.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: dir).appending(path: "markdown-\(name).png"))
            }
        }
    }
}
