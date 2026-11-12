struct OrientationTrackCounts: Equatable {
    var video = 0
    var audio = 0

    static func canReplaceOriginal(expected: Self, inserted: Self, exported: Self) -> Bool {
        expected.video > 0 && inserted == expected && exported == expected
    }
}
