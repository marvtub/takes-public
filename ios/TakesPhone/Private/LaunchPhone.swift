import SwiftUI

enum LaunchPhone {
    @MainActor static func pane(sessionID: String, posts: [SidePost], reload: @escaping () async -> Void) -> AnyView {
        AnyView(EmptyView())
    }
}
