import Foundation
import SwiftUI
import Testing
@testable import Takes

/// The shape your notes repo's takes_export.py writes to _library/social.json.
struct SocialTests {
    static let sample = """
    {"generated":"2026-09-29T13:40:00-07:00","exported":"2026-09-25","x_through":"2026-09-16",
     "sources":{"linkedin":"2026-09-27","followers":"2026-09-27","x":"2026-09-16","refreshed":"2026-09-29 13:40"},
     "hero":{"followers":8856,"followers_gain_8d":42,"followers_spark":[1,2],"new_followers_spark":[1],
       "impr_per_day":178,"month":"Sep","prev_month":"Aug","mom_pct":-73,"impr_spark":[3,4],"rate":2.6,
       "engagements":115,"total_impressions":246902,"peak_month":"Dec 2025","peak_impressions":49010},
     "momentum":{"dates":["2026-09-24","2026-09-25"],"linkedin":[727,1452],"x":[10,null],"annotations":[]},
     "cadence":{"posts":0,"target":3,"week":40,"li_drafts":48,"x_drafts":6},
     "heat":{"dates":["2026-09-28","2026-09-29"],"impressions":[5,null],"li_posts":[0,1],"x_posts":[1,null]},
     "patterns":{"30":{"posts":1,"impressions":189,"avg":189,"analyzed":0,
       "top":[{"title":"A","url":"","date":"2026-09-16","reach":189,"engagements":0,"rate":0.0}],
       "by_day":[{"label":"Wed","avg":189,"count":1}],"by_hook":[],"by_length":[],"by_topic":[]}},
     "recent":[],"monthly_linkedin":[{"month":"2026-09","value":4450}],"monthly_x":[],
     "cross":{"months":[],"linkedin":[],"x":[]},"followers":[{"date":"2026-09-25","value":8856}],
     "audience":[{"title":"Job titles","items":[{"label":"Founder","pct":12.0}]}],
     "top_linkedin":[],"top_x":[],"x_totals":{"posts":1859,"views":418000}}
    """

    @Test func decodesTheExport() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "social-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appending(path: "_library"), withIntermediateDirectories: true)
        try Data(Self.sample.utf8).write(to: SocialData.file(root))
        let d = try #require(SocialData.read(root))
        #expect(d.hero.followers == 8856 && d.patterns["30"]?.by_day.first?.label == "Wed")
        #expect(Signal.month("2026-09") == "Sep" && Signal.day("2026-09-25") == "Sep 25")
    }

    /// A day the source does not cover yet is null, never a zero that reads as a quiet day.
    @Test func daysWithoutDataStayEmpty() throws {
        let d = try JSONDecoder().decode(SocialData.self, from: Data(Self.sample.utf8))
        #expect(d.heat.impressions == [5, nil] && d.momentum.x == [10, nil])
        #expect(d.sources?.linkedin == "2026-09-27")
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let now = try #require(f.date(from: "2026-09-29"))
        #expect(Signal.daysOld("2026-09-27", now: now) == 2 && Signal.daysOld("2026-09-16", now: now) == 13)
    }

    /// X followers are optional: files from before 2026-11-05 have none.
    @Test func xFollowersAreOptional() throws {
        let old = try JSONDecoder().decode(SocialData.self, from: Data(Self.sample.utf8))
        #expect(old.x_followers == nil)
        let new = Self.sample.replacingOccurrences(of: #""top_x":[]"#,
            with: #""top_x":[],"x_followers":[{"date":"2026-11-04","value":432},{"date":"2026-11-05","value":433}]"#)
        let d = try JSONDecoder().decode(SocialData.self, from: Data(new.utf8))
        #expect(d.x_followers?.last?.value == 433)
    }

    /// The YouTube channel decodes when the file has it; older files have none.
    @Test func youtubeDecodes() throws {
        let yt = #""youtube":{"subscribers":2449,"views":219048,"videos":85,"through":"2026-11-04","#
            + #""subscriber_days":[{"date":"2026-11-04","value":2449}],"daily_views":[{"date":"2026-11-04","value":125}],"#
            + #""monthly":[{"month":"2026-11","value":589}],"top":[],"recent":[{"title":"A","url":"","date":"2026-11-03","#
            + #""reach":528,"engagements":4,"rate":0.8}]}"#
        let d = try JSONDecoder().decode(SocialData.self, from: Data(Self.sample.replacingOccurrences(
            of: #""top_x":[]"#, with: #""top_x":[],"# + yt).utf8))
        #expect(d.youtube?.subscribers == 2449 && d.youtube?.recent.first?.reach == 528)
    }

    /// The X board with the real social.json, to look at. `TAKES_SNAPSHOT=/some/dir`.
    @MainActor @Test func xBoardSnapshot() throws {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] else { return }
        let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/Takes")
        let data = try #require(SocialData.read(root))
        let size = CGSize(width: 1000, height: 5200)
        for (platform, (mode, dark)) in ["", "LinkedIn", "X", "YouTube"].flatMap({ p in [("dark", true), ("light", false)].map { (p, $0) } }) {
            let view = ScrollView { SignalPage(data: data, platform: platform) { EmptyView() }.padding(24) }
            let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height).background(Theme.canvas)
                .environment(\.colorScheme, dark ? .dark : .light)))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(origin: .zero, size: size)
            let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height),
                               styleMask: .borderless, backing: .buffered, defer: false)
            win.contentView = host
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try #require(rep.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: dir).appending(path: "\(platform.isEmpty ? "all" : platform.lowercased())-board-\(mode).png"))
        }
    }

    /// The whole board with the top bar and the posts table, in both looks.
    @MainActor @Test func performanceSnapshot() throws {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] else { return }
        let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/Takes")
        let board = PerfBoard()
        board.scanNow(root)
        let size = CGSize(width: 1100, height: 6400)
        UserDefaults.standard.set("", forKey: "perfPlatform")
        for (mode, dark) in [("dark", true), ("light", false)] {
            let view = PerformanceView(board: board, root: root) { _ in }
            let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)
                .environment(\.colorScheme, dark ? .dark : .light)))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(origin: .zero, size: size)
            let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height),
                               styleMask: .borderless, backing: .buffered, defer: false)
            win.contentView = host
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try #require(rep.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: dir).appending(path: "performance-\(mode).png"))
        }
    }

    @Test func postsTablePages() {
        #expect(PerformanceView.pages(0) == 1)
        #expect(PerformanceView.pages(10) == 1)
        #expect(PerformanceView.pages(11) == 2)
        #expect(PerformanceView.pages(21) == 3)
    }
}
