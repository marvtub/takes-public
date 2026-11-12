import CoreGraphics
import Foundation
import ImageIO
import Testing

@Suite struct TakesFacesTests {
    struct FaceResult: Decodable {
        let path: String
        let faces: [[Double]]
        let error: String?
    }

    @Test func eachInputProducesAnOrderedRoundedJSONResult() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let build = root.appendingPathComponent(".build")
        let buildFolders = try FileManager.default.contentsOfDirectory(at: build,
                                                                        includingPropertiesForKeys: nil)
        let candidates = [build.appendingPathComponent("debug/takes-faces")] +
            buildFolders.map { $0.appendingPathComponent("debug/takes-faces") }
        let executable = try #require(candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        })
        let creator = root.appendingPathComponent("assets/onboarding/creator.jpg")
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TakesFacesTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // creator.jpg's face is centred top to bottom (y 0.296, h 0.406), so it reads the same in
        // top- and bottom-origin coordinates. Put the photo in the top half of a canvas twice as
        // tall: the face then starts near 0.15 from the top, and near 0.65 if y were flipped.
        let face = folder.appendingPathComponent("face-on-top.png")
        try writeOnTopHalf(creator, to: face)
        let missing = folder.appendingPathComponent("missing.jpg")

        #expect(FileManager.default.fileExists(atPath: face.path))

        let output = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = [face.path, missing.path]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(whereSeparator: \.isNewline)
        try #require(lines.count == 2)
        let results = try lines.map { try JSONDecoder().decode(FaceResult.self, from: Data($0.utf8)) }

        #expect(results.map(\.path) == [face.path, missing.path])
        #expect(results[0].error == nil)
        #expect(!results[0].faces.isEmpty)
        for bounds in results[0].faces {
            try #require(bounds.count == 4)
            #expect(bounds.allSatisfy { 0 ... 1 ~= $0 })
            #expect(bounds[0] + bounds[2] <= 1.001)
            #expect(bounds[1] + bounds[3] <= 1.001)
            #expect(bounds.allSatisfy {
                abs($0 * 1_000 - ($0 * 1_000).rounded()) < 0.000_001
            })
        }
        let largestFace = try #require(results[0].faces.max { $0[2] * $0[3] < $1[2] * $1[3] })
        #expect(largestFace[1] < 0.25) // The face is in the top half: y counts from the top.

        #expect(results[1].faces.isEmpty)
        #expect(!(results[1].error ?? "").isEmpty)
    }

    /// Draws the image in the top half of a canvas twice its height (white below) and saves a PNG.
    func writeOnTopHalf(_ source: URL, to target: URL) throws {
        let src = try #require(CGImageSourceCreateWithURL(source as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let w = image.width, h = image.height
        let context = try #require(CGContext(data: nil, width: w, height: h * 2, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h * 2))
        context.draw(image, in: CGRect(x: 0, y: h, width: w, height: h))  // CG's y is from the bottom
        let out = try #require(context.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(target as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, out, nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
