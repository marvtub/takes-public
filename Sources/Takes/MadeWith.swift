import Foundation

/// Which AI model made a file (2026-10-06). The takes MCP writes `.models.json` in the file's folder
/// (generated/, storyboard/): file name -> "Nano Banana 2.1", "GPT Image 2.5 Flare", "Seedance 2.5".
/// The Assets tab and the storyboard show it in small grey type.
enum MadeWith {
    nonisolated static func label(for url: URL) -> String? {
        let note = url.deletingLastPathComponent().appending(path: ".models.json")
        guard let data = try? Data(contentsOf: note),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        return map[url.lastPathComponent]
    }
}
