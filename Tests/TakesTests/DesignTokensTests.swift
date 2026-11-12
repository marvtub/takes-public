import Testing
@testable import Takes

/// DS (DesignTokens.swift) is made from design/system/tokens.json (2026-11-06). These pin a few
/// values the app already draws with, so a token change that would move the app shows here.
struct DesignTokensTests {
    @Test func radiiMatchTheApp() {
        #expect(DS.Radius.panel == Theme.radius)
        #expect(DS.Radius.r12 == 12)
        #expect(DS.Radius.card == 16)
        #expect(DS.Radius.r3 == 3)
    }

    @Test func spacingScale() {
        let scale = [DS.Space.s2, DS.Space.s4, DS.Space.s6, DS.Space.s8, DS.Space.s10, DS.Space.s12,
                     DS.Space.s14, DS.Space.s16, DS.Space.s20, DS.Space.s24, DS.Space.s28, DS.Space.s32]
        #expect(scale == [2, 4, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32])
    }

    @Test func fontSizes() {
        #expect(DS.FontSize.xxs == 10.5)
        #expect(DS.FontSize.md == 12.5)
        #expect(DS.FontSize.body == 13)
        // Display sizes are what Theme.display takes: it draws 26 at 20.8 px (fs-d-lg).
        #expect(DS.FontSize.displayLg == 26)
        #expect(DS.FontSize.displayXl == 32)
    }
}
