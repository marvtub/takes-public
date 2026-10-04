import Testing
@testable import Takes

struct ReleaseTests {
    @Test func commandQuotesTheRepoAndRunsMainsScript() {
        let c = Releaser.command("/Users/a b/it's")
        #expect(c.contains("git -C '/Users/a b/it'\\''s' fetch -q origin"))
        #expect(c.contains("TAKES_REPO='/Users/a b/it'\\''s' bash <(git -C '/Users/a b/it'\\''s' show origin/main:scripts/public/release.sh)"))
    }
}
