/// Features that stay private for now (2026-10-04). The Comments copilot and the Performance
/// board drive the user's own signed-in Chrome with personal runbooks, so the public copy turns
/// them off (scripts/public/export.py sets this to false). The iPhone has the same switch in Look.swift.
enum Features {
    static let socialBoards = false
}
