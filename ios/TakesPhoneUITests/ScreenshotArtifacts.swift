import Foundation

enum ScreenshotArtifacts {
    enum WriteError: LocalizedError {
        case outputDirectoryMissing

        var errorDescription: String? {
            "TAKES_SHOTS is required for this screenshot run"
        }
    }

    @discardableResult
    static func write(_ png: Data, named name: String, directory: String?, required: Bool) throws -> URL? {
        guard let directory, !directory.isEmpty else {
            if required { throw WriteError.outputDirectoryMissing }
            return nil
        }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(name + ".png")
        try png.write(to: destination, options: .atomic)
        return destination
    }
}

#if os(iOS)
import XCTest

extension XCTestCase {
    func writeScreenshot(
        _ screenshot: XCUIScreenshot,
        named name: String,
        requiresOutputDirectory: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let directory = ProcessInfo.processInfo.environment["TAKES_SHOTS"]
        do {
            try ScreenshotArtifacts.write(
                screenshot.pngRepresentation,
                named: name,
                directory: directory,
                required: requiresOutputDirectory
            )
        } catch {
            let destination = directory.map { URL(fileURLWithPath: $0).appendingPathComponent(name + ".png").path }
                ?? "TAKES_SHOTS"
            XCTFail("Could not save screenshot to \(destination): \(error.localizedDescription)", file: file, line: line)
        }
    }
}
#endif
