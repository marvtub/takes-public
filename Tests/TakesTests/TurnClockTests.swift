import Testing
@testable import Takes

struct TurnClockTests {
    @Test func aClaudeTurnLineHasItsTimesAndCacheShare() {
        var c = TurnClock(agent: "claude", now: 100)
        c.process = "open"
        c.saw([#"{"type":"system","subtype":"init"}"#], now: 100.4)
        c.saw([#"{"type":"assistant","message":{}}"#], now: 101.5)
        c.saw([#"{"type":"result","usage":{"input_tokens":2000,"cache_read_input_tokens":54000,"cache_creation_input_tokens":4000}}"#], now: 103)
        #expect(c.line(outcome: "ok", now: 103.25)
            == "chat turn claude open: first line 0.40 s, answer 1.50 s, done 3.25 s, ok, cache 90% of 60k")
    }

    @Test func codexCountsCachedTokensInsideItsInput() {
        var c = TurnClock(agent: "codex", now: 0)
        c.saw([#"{"type":"item.completed"}"#, #"{"type":"turn.completed","usage":{"input_tokens":10000,"cached_input_tokens":7500}}"#], now: 2)
        #expect(c.line(outcome: "ok", now: 2).hasSuffix("cache 75% of 10k"))
    }

    @Test func aTurnWithNoOutputSaysSo() {
        let c = TurnClock(agent: "pi", now: 0)
        #expect(c.line(outcome: "error", now: 1) == "chat turn pi once: first line –, answer –, done 1.00 s, error")
    }
}
