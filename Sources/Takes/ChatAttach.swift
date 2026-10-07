import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Files in the chat (2026-10-04): drag files or screenshots onto a chat, or paste an image with
// ⌘V, as in Hive. Each file goes with the next message as its path alone on a line, so Claude
// reads it and the bubble shows it as a card (ChatRefs). A file from Finder keeps its own path.
// An image with no file (a screenshot thumbnail, a picture from a web page, a copied image) is
// saved first in Application Support/Takes/Chat files, as lossless WebP (2026-10-04: the same
// pixels, about half the size of a PNG) when cwebp is installed, else as a PNG.

enum ChatAttach {
    static let types: [UTType] = [.fileURL, .image]

    static var folder: URL { ClaudeChat.boardFolder.appending(path: "Chat files") }

    /// The message with the files after it, each path alone on its line.
    static func message(_ text: String, files: [URL]) -> String {
        guard !files.isEmpty else { return text }
        let lines = files.map(\.path).joined(separator: "\n")
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? lines : t + "\n\n" + lines
    }

    /// Adds the dropped items to the chat's files. False when none of them is a file or an image.
    @MainActor static func take(_ providers: [NSItemProvider], into chat: ClaudeChat) -> Bool {
        take(providers) { add($0, to: chat) }
    }

    /// The same for any chat that keeps its own files, like Muse's (2026-10-06).
    @MainActor static func take(_ providers: [NSItemProvider], add: @escaping @MainActor (URL) -> Void) -> Bool {
        let usable = providers.filter { p in types.contains { p.hasItemConformingToTypeIdentifier($0.identifier) } }
        for p in usable {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    Task { @MainActor in add(url) }
                }
            } else {
                p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let url = save(data) else { return }
                    Task { @MainActor in add(url) }
                }
            }
        }
        return !usable.isEmpty
    }

    /// ⌘V: files or an image on the clipboard become files of the chat. False when the clipboard
    /// has text, so the box pastes it as usual. Reads the clipboard; never writes it.
    @MainActor static func paste(into chat: ClaudeChat) -> Bool {
        paste { add($0, to: chat) }
    }

    @MainActor static func paste(add: @escaping @MainActor (URL) -> Void) -> Bool {
        let pb = NSPasteboard.general
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty {
            urls.forEach { add($0) }
            return true
        }
        guard pb.string(forType: .string) == nil,
              let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation else { return false }
        Task.detached {
            guard let url = save(tiff) else { return }
            await MainActor.run { add(url) }
        }
        return true
    }

    @MainActor private static func add(_ url: URL, to chat: ClaudeChat) {
        if !chat.attachments.contains(url) { chat.attachments.append(url) }
    }

    nonisolated static let cwebp = ["/opt/homebrew/bin/cwebp", "/usr/local/bin/cwebp"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Saves image data as lossless WebP, else as a PNG; returns its file. Slow: not on the main thread.
    nonisolated static func save(_ data: Data) -> URL? {
        guard let png = savePNG(data) else { return nil }
        guard let cwebp else { return png }
        let webp = png.deletingPathExtension().appendingPathExtension("webp")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cwebp)
        // -exact keeps the colour under transparent pixels too: every pixel stays as it was.
        p.arguments = ["-quiet", "-lossless", "-exact", "-z", "6", "-metadata", "icc", png.path, "-o", webp.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return png }
        p.waitUntilExit()
        let size = { (u: URL) in (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        guard p.terminationStatus == 0, size(webp) > 0, size(webp) < size(png) else {
            try? FileManager.default.removeItem(at: webp)
            return png
        }
        try? FileManager.default.removeItem(at: png)
        return webp
    }

    nonisolated private static func savePNG(_ data: Data) -> URL? {
        guard let rep = NSBitmapImageRep(data: data),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Image \(f.string(from: Date())) \(UUID().uuidString.prefix(4)).png"
        let dir = folder
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)
        return (try? png.write(to: url)) != nil ? url : nil
    }
}

/// The files waiting to go with the next message, above the box: a small frame for an image,
/// an icon and the name for anything else. × takes one out.
struct AttachedFiles: View {
    let files: [URL]
    let remove: (URL) -> Void

    init(files: [URL], remove: @escaping (URL) -> Void) { self.files = files; self.remove = remove }
    init(chat: ClaudeChat) { self.init(files: chat.attachments) { url in chat.attachments.removeAll { $0 == url } } }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(files, id: \.self) { url in
                    AttachedFile(url: url) { remove(url) }
                }
            }
            .padding(.top, 6).padding(.trailing, 6)
        }
    }
}

private struct AttachedFile: View {
    let url: URL
    let remove: () -> Void
    @State private var image: NSImage?
    @State private var hover = false

    private var isImage: Bool { UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false }

    var body: some View {
        Group {
            if isImage {
                ZStack {
                    Theme.hover
                    if let image { Image(nsImage: image).resizable().scaledToFill() }
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "doc").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Text(url.lastPathComponent).font(Theme.sans(11.5)).foregroundStyle(Theme.ink)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 140)
                }
                .padding(.horizontal, 10).frame(height: 32)
                .background(Theme.hover, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 0.5))
        .overlay(alignment: .topTrailing) {
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold)).foregroundStyle(Theme.paper)
                    .frame(width: 16, height: 16).background(Theme.ink, in: Circle())
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .opacity(hover ? 1 : 0)
            .help("Take it out")
        }
        .onHover { hover = $0 }
        .help(url.path)
        .task(id: url) {
            guard isImage else { return }
            let u = url
            image = await Task.detached { Self.thumb(u) }.value
        }
    }

    nonisolated private static func thumb(_ url: URL) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 160,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
}

/// Over a chat while files are dragged onto it.
struct DropHint: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .background(Theme.raised.opacity(0.88), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                Label("Drop to add to the message", systemImage: "paperclip")
                    .font(Theme.sans(13, .medium)).foregroundStyle(Theme.ink)
            }
            .padding(8)
            .allowsHitTesting(false)
    }
}
