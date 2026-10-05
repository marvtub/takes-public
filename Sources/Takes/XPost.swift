import AppKit
import SwiftUI

// The X post of the session as the X timeline shows it (web, light mode): one tweet, or a thread
// with the avatars joined by a line. The timeline cuts a long tweet after 280 characters with
// "Show more" (X Premium allows up to 25,000). Click a tweet to edit the thread: each tweet has
// its own editor, "Add post" adds one, and the file keeps them apart with a line of "---".

/// X's colours and type (the web timeline, light mode).
enum XFeed {
    static let background = Color.white
    static let ink = Color(red: 15 / 255, green: 20 / 255, blue: 25 / 255)           // #0F1419
    static let muted = Color(red: 83 / 255, green: 100 / 255, blue: 113 / 255)       // #536471
    static let line = Color(red: 207 / 255, green: 217 / 255, blue: 222 / 255)       // #CFD9DE
    static let divider = Color(red: 239 / 255, green: 243 / 255, blue: 244 / 255)    // #EFF3F4
    static let blue = Color(red: 29 / 255, green: 155 / 255, blue: 240 / 255)        // #1D9BF0
    static let inkNS = NSColor(srgbRed: 15 / 255, green: 20 / 255, blue: 25 / 255, alpha: 1)
    static let blueNS = NSColor(srgbRed: 29 / 255, green: 155 / 255, blue: 240 / 255, alpha: 1)
    /// The preview follows the app's text size (⌘+ / ⌘−), like the rest of Takes.
    static var textFont: NSFont { NSFont.systemFont(ofSize: 15 * TextSize.shared.factor) }
    static var lineHeight: CGFloat { (20 * TextSize.shared.factor).rounded() }
    /// The timeline shows this many characters of a long tweet, then "Show more".
    static let feedCut = 280

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size * TextSize.shared.factor, weight: weight) }

    /// The tweet with hashtags, mentions and links in blue.
    static func styled(_ text: String) -> AttributedString {
        let ns = NSMutableAttributedString(string: text)
        for r in PostFile.tags(text) { ns.addAttribute(.foregroundColor, value: blueNS, range: r) }
        return (try? AttributedString(ns, including: \.appKit)) ?? AttributedString(text)
    }

    /// The part of a long tweet the timeline shows.
    static func cut(_ text: String) -> (shown: String, more: Bool) {
        guard text.count > feedCut else { return (text, false) }
        return (String(text.prefix(feedCut)).trimmingCharacters(in: .whitespacesAndNewlines) + "…", true)
    }
}

/// The thread as X shows it. `text` is the whole file body; tweets are split at "---" lines.
struct XThreadCard: View {
    @Binding var text: String
    var draft = ""
    let media: URL?
    @Binding var expanded: Bool
    let highlights: [String]
    let reveal: (quote: String, token: Int)?
    let focusToken: Int
    let onSelect: (String) -> Void
    let onComment: () -> Void
    let onExpand: () -> Void
    var onCollapse: () -> Void = {}
    @AppStorage("xName") private var name = "You"
    @AppStorage("xHandle") private var handle = "you"
    @State private var editingProfile = false
    @State private var added: Int?

    /// While editing, empty tweets stay (a tweet you just added); the feed drops them.
    private var tweets: [String] {
        let all = PostFile.tweets(text, keepEmpty: expanded)
        return all.isEmpty ? [""] : all
    }

    var body: some View {
        let ts = tweets
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(ts.enumerated()), id: \.offset) { i, t in
                row(i, t, count: ts.count)
            }
            if expanded {
                HStack(spacing: 12) {
                    Button { addTweet() } label: {
                        Label("Add post", systemImage: "plus.circle.fill")
                            .font(XFeed.font(15, .semibold)).foregroundStyle(XFeed.blue)
                    }
                    .buttonStyle(.plain)
                    .help("Add a post to the thread")
                    Spacer()
                    Button("show less", action: onCollapse)
                        .buttonStyle(.plain)
                        .font(XFeed.font(15)).foregroundStyle(XFeed.muted)
                        .help("Back to the timeline view")
                }
                .padding(.leading, 68).padding(.trailing, 16).padding(.bottom, 14)
            }
        }
        .background(XFeed.background)
        .overlay(alignment: .top) { XFeed.divider.frame(height: 1) }
        .overlay(alignment: .bottom) { XFeed.divider.frame(height: 1) }
        .environment(\.colorScheme, .light)
        .popover(isPresented: $editingProfile, arrowEdge: .bottom) { profileEditor }
    }

    // MARK: One tweet

    private func row(_ i: Int, _ tweet: String, count: Int) -> some View {
        let last = i == count - 1
        return HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                avatar
                if !last { XFeed.line.frame(width: 2).frame(maxHeight: .infinity) }
            }
            .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                header(i, count: count)
                textBlock(i, tweet, count: count)
                if i == 0, let media {
                    PostMedia(url: media)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(XFeed.line))
                        .padding(.top, 10)
                }
                actions(i).padding(.top, 10).padding(.bottom, last ? 12 : 16)
            }
        }
        // The thread line may only fill the row's own height, not grow it.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16).padding(.top, 12)
    }

    private func header(_ i: Int, count: Int) -> some View {
        HStack(spacing: 4) {
            Text(name).font(XFeed.font(15, .bold)).foregroundStyle(XFeed.ink).lineLimit(1)
            Image(systemName: "checkmark.seal.fill").font(.system(size: 15)).foregroundStyle(XFeed.blue)
            Text("@\(handle) · now").font(XFeed.font(15)).foregroundStyle(XFeed.muted).lineLimit(1)
            Spacer(minLength: 8)
            if expanded && count > 1 {
                Text("\(i + 1)/\(count)").font(Theme.mono(11)).foregroundStyle(XFeed.muted)
                Button { removeTweet(i) } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(XFeed.muted)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove this post from the thread")
            } else {
                Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).foregroundStyle(XFeed.muted)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { editingProfile = true }
        .help("Change the name or handle")
    }

    @ViewBuilder private func textBlock(_ i: Int, _ tweet: String, count: Int) -> some View {
        if expanded {
            VStack(alignment: .trailing, spacing: 2) {
                PostEditor(text: Binding(get: { tweet }, set: { setTweet(i, $0) }),
                           identity: "\(draft)#\(i)/\(count)", highlights: highlights, reveal: reveal,
                           focusToken: focusToken, onSelect: onSelect, onComment: onComment,
                           look: .x, placeholder: i == 0 ? "What's happening?" : "Add another post",
                           autofocus: i == (added ?? 0))
                let n = tweet.count
                if n > XFeed.feedCut - 40 {
                    Text(n > XFeed.feedCut ? "\(n) · Show more after \(XFeed.feedCut)" : "\(n) / \(XFeed.feedCut)")
                        .font(Theme.mono(10.5))
                        .foregroundStyle(n > PostPlatform.x.limit ? Theme.accentInk : XFeed.muted)
                        .help("The timeline shows \(XFeed.feedCut) characters of a post, then Show more. X Premium allows up to \(PostPlatform.x.limit.formatted()).")
                }
            }
        } else if tweet.isEmpty {
            Text("What's happening?").font(XFeed.font(15)).foregroundStyle(XFeed.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: onExpand)
        } else {
            let c = XFeed.cut(tweet)
            VStack(alignment: .leading, spacing: 2) {
                Text(XFeed.styled(c.shown))
                    .font(XFeed.font(15)).foregroundStyle(XFeed.ink)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if c.more { Text("Show more").font(XFeed.font(15)).foregroundStyle(XFeed.blue) }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onExpand)
            .help("Click to edit the thread")
        }
    }

    private func actions(_ i: Int) -> some View {
        HStack(spacing: 0) {
            stat("bubble.left", i == 0 ? "12" : "3", help: "Comment for Takes", perform: onComment)
            stat("arrow.2.squarepath", i == 0 ? "8" : "")
            stat("heart", i == 0 ? "96" : "14")
            stat("chart.bar.xaxis", i == 0 ? "4.2K" : "1.1K")
            HStack(spacing: 14) {
                Image(systemName: "bookmark")
                Image(systemName: "square.and.arrow.up")
            }
            .font(XFeed.font(15)).foregroundStyle(XFeed.muted)
        }
    }

    private func stat(_ icon: String, _ n: String, help: String? = nil, perform: @escaping () -> Void = {}) -> some View {
        Button(action: perform) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 15))
                Text(n).font(XFeed.font(13))
            }
            .foregroundStyle(XFeed.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? "")
    }

    // MARK: Editing the thread

    private func setTweet(_ i: Int, _ new: String) {
        var ts = PostFile.tweets(text, keepEmpty: true)
        if ts.isEmpty { ts = [""] }
        guard i < ts.count, ts[i] != new else { return }
        ts[i] = new
        text = PostFile.thread(ts)
    }

    private func addTweet() {
        var ts = PostFile.tweets(text, keepEmpty: true)
        if ts.isEmpty { ts = [""] }
        ts.append("")
        added = ts.count - 1
        text = PostFile.thread(ts)
    }

    private func removeTweet(_ i: Int) {
        var ts = PostFile.tweets(text, keepEmpty: true)
        guard i < ts.count, ts.count > 1 else { return }
        ts.remove(at: i)
        added = nil
        text = PostFile.thread(ts)
    }

    // MARK: Profile

    private var avatar: some View {
        Group {
            if let img = LinkedIn.photo {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    XFeed.ink.opacity(0.85)
                    Text(String(name.prefix(1))).font(XFeed.font(17, .bold)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
    }

    private var profileEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How you appear on X").font(Theme.sans(13, .bold))
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            TextField("Handle", text: $handle).textFieldStyle(.roundedBorder)
            Text("The photo is the one on your LinkedIn post.").font(Theme.sans(11)).foregroundStyle(Theme.muted)
        }
        .padding(14)
        .frame(width: 300)
    }
}
