import Foundation
import Testing
@testable import Takes

/// The Plugins board: a removal is saved, an install undoes it, and others stay as they were.
struct PluginsTests {
    @Test func removeAndInstallAgain() {
        let a = "test-a-\(UUID().uuidString)", b = "test-b-\(UUID().uuidString)"
        defer { Plugins.setInstalled(a, true); Plugins.setInstalled(b, true) }
        #expect(Plugins.isInstalled(a))
        Plugins.setInstalled(a, false)
        Plugins.setInstalled(b, false)
        #expect(!Plugins.isInstalled(a) && !Plugins.isInstalled(b))
        Plugins.setInstalled(a, true)
        #expect(Plugins.isInstalled(a) && !Plugins.isInstalled(b))
        #expect(Set(Plugins.all.map(\.id)).isSubset(of: Set(Plugins.available.map(\.id))))
        let ids = Plugins.available.map(\.id)
        #expect(Set(ids).count == ids.count, "no two plugins share an id")
    }
}
