import SwiftUI

@MainActor final class AutopostWatch: ObservableObject {
    func load(_ model: Model, _ sessionID: String, _ post: PlatformPost?, reload: (() async -> Void)? = nil) async {}
    func part(_ model: Model, post: PlatformPost, date: Date, zone: TimeZone, open: OpenURLAction, close: @escaping () -> Void) -> SchedulePart? { nil }
    func label(_ post: PlatformPost) -> ScheduleLabel? { nil }
}
