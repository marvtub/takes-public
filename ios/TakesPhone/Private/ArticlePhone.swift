import SwiftUI

enum ArticlePhone {
    @MainActor static func pane(sessionID: String, post: PlatformPost, reload: @escaping () async -> Void) -> AnyView {
        AnyView(EmptyView())
    }
}
