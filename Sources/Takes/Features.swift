/// Features that stay private for now (2026-10-04). The Comments copilot and the Performance
/// board drive the user's own signed-in Chrome with personal runbooks, so the public copy turns
/// them off (scripts/public/export.py sets the Built values to false). The iPhone has the same switch in Look.swift.
enum Features {
    /// What this build has (2026-10-22). Background jobs read these; screens read the names below.
    enum Built {
        static let socialBoards = false
        /// The blog article (2026-10-05): the Article side of the post tab, shown as the user's own
        /// blog shows it. Private too; the public copy hides it (export.py sets this to false).
        static let blog = false
    }
    /// Off in the public copy and in Public view (PublicView.swift, 2026-10-22).
    static var socialBoards: Bool { Built.socialBoards && !PublicView.on }
    static var blog: Bool { Built.blog && !PublicView.on }
}
