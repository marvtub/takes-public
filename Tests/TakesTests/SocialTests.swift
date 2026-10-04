import Foundation
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
}
