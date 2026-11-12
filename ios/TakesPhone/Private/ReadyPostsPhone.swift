import SwiftUI

enum ReadyPostsPhone {
    @MainActor static func feed(plan: PlanData, present: @escaping (AnyView?) -> Void,
                                openPost: @escaping (String, String) -> Void, fallback: @escaping () -> AnyView) -> AnyView {
        fallback()
    }
}
