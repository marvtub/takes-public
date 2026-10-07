import Foundation
import MLX
import Tokenizers

public enum EmbeddingTask: String, CaseIterable, Sendable {
    case search, document, code, similarity, classification, clustering, question, fact, raw
    public func format(_ text: String, title: String? = nil) -> String {
        switch self {
        case .document: return "title: \(title ?? "none") | text: \(text)"
        case .search: return "task: search result | query: \(text)"
        case .code: return "task: code retrieval | query: \(text)"
        case .similarity: return "task: sentence similarity | query: \(text)"
        case .classification: return "task: classification | query: \(text)"
        case .clustering: return "task: clustering | query: \(text)"
        case .question: return "task: question answering | query: \(text)"
        case .fact: return "task: fact checking | query: \(text)"
        case .raw: return text
        }
    }
}

/// Serial actor keeps MLX execution off the UI actor and prevents overlapping forwards.
public actor TextEncoder {
    private let model: TextModel
    private let tokenizer: any Tokenizer
    private var vision: VisionModel?
    private var audio: AudioModel?
    public init(directory: URL, float32: Bool = false, progress: (@Sendable (String) -> Void)? = nil) async throws {
        progress?("loading_tokenizer")
        tokenizer = try await AutoTokenizer.from(modelFolder: directory)
        progress?("loading_weights")
        model = try TextModel(directory: directory, float32: float32)
        progress?("ready")
    }
    public func tokenize(_ texts: [String], task: EmbeddingTask = .raw) throws -> [[Int]] {
        guard !texts.isEmpty else { throw EmbeddingError.invalid("Empty batch") }
        let rows = texts.map { tokenizer.encode(text:task.format($0),addSpecialTokens:true) }
        guard rows.allSatisfy({ !$0.isEmpty && $0.count <= 8192 }) else { throw EmbeddingError.invalid("Text exceeds 8192 tokens; chunk explicitly") }
        return rows
    }
    public func encode(_ texts: [String], task: EmbeddingTask = .raw, dimensions: Int = 768) throws -> [[Float]] {
        let rows = try tokenize(texts,task:task)
        let length = rows.map(\.count).max()!
        let ids = rows.map { $0 + Array(repeating:0,count:length-$0.count) }
        let mask = rows.map { Array(repeating:1,count:$0.count) + Array(repeating:0,count:length-$0.count) }
        return try encodeTokens(ids:ids,mask:mask,dimensions:dimensions)
    }
    public func encodeTokens(ids: [[Int]], mask: [[Int]], dimensions: Int = 768) throws -> [[Float]] {
        let values = try model.encode(ids:ids,mask:mask,dimensions:dimensions).embeddings.asArray(Float.self)
        guard values.allSatisfy(\.isFinite) else { throw EmbeddingError.invalid("Non-finite embedding") }
        return stride(from:0,to:values.count,by:dimensions).map { Array(values[$0..<$0+dimensions]) }
    }
    public func weightFormat() -> String { model.weightFormat }
    public func memory() -> [String:Int] { ["mlx_active_bytes":Memory.activeMemory,"mlx_peak_bytes":Memory.peakMemory,"mlx_cache_bytes":Memory.cacheMemory] }
    public func enableVision(directory: URL) throws {
        vision = try VisionModel(directory:directory,float32:model.dtype == .float32)
    }
    public func imageTokenIDs(softTokenCount: Int) throws -> [Int] {
        guard (1...280).contains(softTokenCount) else { throw EmbeddingError.invalid("Image soft-token count must be 1...280") }
        let text = "<|image>" + String(repeating:"<|image|>",count:softTokenCount) + "<image|>"
        return tokenizer.encode(text:text,addSpecialTokens:true)
    }
    public func encodeImage(_ image: PreparedImage, dimensions: Int = 768) throws -> [Float] {
        guard let vision else { throw EmbeddingError.invalid("Load vision weights with enableVision first") }
        guard [128,256,512,768].contains(dimensions) else { throw EmbeddingError.invalid("Unsupported embedding dimensions") }
        let ids = try imageTokenIDs(softTokenCount:image.softTokenCount)
        let features = vision.encode(image)
        let vector = try model.encode(ids:[ids],mask:[Array(repeating:1,count:ids.count)],dimensions:dimensions,imageFeatures:features).embeddings.asArray(Float.self)
        guard vector.allSatisfy(\.isFinite) else { throw EmbeddingError.invalid("Non-finite image embedding") }
        return vector
    }
    public func encodeImage(url: URL, maxSoftTokens: Int = 280, dimensions: Int = 768) throws -> [Float] {
        try encodeImage(ImageProcessor.prepare(RGBImage.load(url),maxSoftTokens:maxSoftTokens),dimensions:dimensions)
    }
    public func disableVision() { vision=nil; Memory.clearCache() }
    public func enableAudio(directory: URL) throws { audio=try AudioModel(directory:directory,float32:model.dtype == .float32) }
    public func disableAudio() { audio=nil; Memory.clearCache() }
    public func audioTokenIDs(softTokenCount:Int) throws -> [Int] {
        guard (1...750).contains(softTokenCount) else { throw EmbeddingError.invalid("Audio soft-token count must be 1...750") }
        return tokenizer.encode(text:"<|audio>"+String(repeating:"<|audio|>",count:softTokenCount)+"<audio|>",addSpecialTokens:true)
    }
    public func encodeAudio(_ prepared:PreparedAudio,dimensions:Int = 768) throws -> [Float] {
        guard let audio else { throw EmbeddingError.invalid("Load audio weights with enableAudio first") }
        guard [128,256,512,768].contains(dimensions) else { throw EmbeddingError.invalid("Unsupported embedding dimensions") }
        let ids=try audioTokenIDs(softTokenCount:prepared.softTokenCount)
        let vector=try model.encode(ids:[ids],mask:[Array(repeating:1,count:ids.count)],dimensions:dimensions,imageFeatures:audio.encode(prepared),mediaTokenID:258881).embeddings.asArray(Float.self)
        guard vector.allSatisfy(\.isFinite) else { throw EmbeddingError.invalid("Non-finite audio embedding") }
        return vector
    }
    public func encodeAudio(url:URL,dimensions:Int = 768) throws -> [Float] {
        try encodeAudio(AudioProcessor.prepare(samples:AudioProcessor.loadWAV(url)),dimensions:dimensions)
    }
}
