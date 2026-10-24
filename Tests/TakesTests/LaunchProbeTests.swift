import Testing
import Foundation
@testable import Takes

struct LaunchProbeTests {
    @Test func keepsTheSampleOnlyForAFreezeOf300msOrMore() {
        #expect(!LaunchProbe.keep([]))
        #expect(!LaunchProbe.keep([120, 299]))
        #expect(LaunchProbe.keep([150, 300]))
        #expect(LaunchProbe.keep([940]))
    }
}
