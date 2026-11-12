import Foundation

// Runs without UIKit: swiftc TakesPhoneUITests/ScreenshotArtifacts.swift tests/ScreenshotArtifactsTests.swift.
@main
struct ScreenshotArtifactsTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("takes-phone-shots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let destination = try ScreenshotArtifacts.write(
            Data([0x89, 0x50, 0x4e, 0x47]),
            named: "screen",
            directory: root.appendingPathComponent("valid").path,
            required: true
        )
        precondition(destination != nil)
        let written = try Data(contentsOf: destination!)
        precondition(written == Data([0x89, 0x50, 0x4e, 0x47]))

        let blocked = root.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: blocked)
        do {
            _ = try ScreenshotArtifacts.write(Data(), named: "screen", directory: blocked.path, required: true)
            preconditionFailure("an invalid destination must report the write error")
        } catch {}

        do {
            _ = try ScreenshotArtifacts.write(Data(), named: "screen", directory: nil, required: true)
            preconditionFailure("a required run must reject a missing output directory")
        } catch {}

        print("Screenshot artifacts: all checks passed")
    }
}
