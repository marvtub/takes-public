import Foundation
import MLX
import MLXNN

public enum EmbeddingError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String { switch self { case .invalid(let s): return s } }
}

public struct TextConfiguration: Decodable, Sendable {
    public let model_type: String
    public let vocab_size, hidden_size, intermediate_size, num_hidden_layers: Int
    public let num_attention_heads, num_key_value_heads, head_dim: Int
    public let hidden_size_per_layer_input, embedding_dim, sliding_window: Int
    public let rms_norm_eps: Float
    public let layer_types: [String]
    public let per_layer_config: [String: [String: Int]]
    public let rope_parameters: [String: RopeConfiguration]
    public struct RopeConfiguration: Decodable, Sendable {
        public let rope_theta: Float
        public let rope_type: String
    }
    public static func load(_ url: URL) throws -> TextConfiguration {
        struct Wrapper: Decodable { let text_config: TextConfiguration }
        let data = try Data(contentsOf: url)
        let result = try JSONDecoder().decode(Wrapper.self, from: data).text_config
        guard result.model_type == "embedding_gemma2_text",
              result.layer_types.count == result.num_hidden_layers,
              result.layer_types.allSatisfy({ ["full_attention", "sliding_attention"].contains($0) }),
              result.hidden_size_per_layer_input > 0, result.hidden_size > 0,
              result.num_hidden_layers > 0, result.num_attention_heads > 0,
              result.num_key_value_heads > 0, result.sliding_window >= 0,
              Set(result.layer_types).isSubset(of: Set(result.rope_parameters.keys)),
              result.embedding_dim == 768,
              result.rope_parameters.values.allSatisfy({ $0.rope_type == "default" && $0.rope_theta > 0 }) else {
            throw EmbeddingError.invalid("Unsupported EmbeddingGemma 2 configuration")
        }
        return result
    }
}

/// Immutable weights; use from a single executor. Text only, with no KV cache.
public final class TextModel {
    public let config: TextConfiguration
    public let dtype: DType
    private let weights: WeightStore
    public var weightFormat: String { weights.format }

    public init(directory: URL, float32: Bool = false) throws {
        config = try TextConfiguration.load(directory.appendingPathComponent("config.json"))
        let loaded = try MLX.loadArrays(url: directory.appendingPathComponent("model.safetensors"))
        dtype = float32 ? .float32 : .bfloat16
        var selected = [String: MLXArray]()
        for (name, value) in loaded {
            let key = name.hasPrefix("model.") ? String(name.dropFirst(6)) : name
            guard key.hasPrefix("language_model.") else { continue }
            selected[String(key.dropFirst("language_model.".count))] = value
        }
        // Validate every tensor before any forward pass, including unexpected weights.
        var shapes: [String: [Int]] = [
            "embed_tokens.weight": [config.vocab_size, config.hidden_size],
            "embedding_projection.weight": [config.embedding_dim, config.hidden_size],
            "norm.weight": [config.hidden_size],
            "ple.per_layer_model_projection.weight": [config.num_hidden_layers * config.hidden_size_per_layer_input, config.hidden_size],
            "ple.per_layer_projection_norm.weight": [config.hidden_size_per_layer_input]
        ]
        for i in 0..<config.num_hidden_layers {
            let p = "layers.\(i).", c = config.per_layer_config[String(format: "%02d", i)] ?? [:]
            let h = c["head_dim"] ?? config.head_dim
            let kv = c["num_key_value_heads"] ?? config.num_key_value_heads
            guard h % 2 == 0, kv > 0, config.num_attention_heads % kv == 0 else {
                throw EmbeddingError.invalid("Invalid attention dimensions at layer \(i)")
            }
            for n in ["input_layernorm", "post_attention_layernorm", "pre_feedforward_layernorm", "post_feedforward_layernorm", "ple_block.post_per_layer_input_norm"] {
                shapes[p+n+".weight"] = [config.hidden_size]
            }
            shapes[p+"layer_scalar"] = [1]
            shapes[p+"self_attn.q_proj.weight"] = [config.num_attention_heads*h, config.hidden_size]
            for n in ["k_proj", "v_proj"] { shapes[p+"self_attn.\(n).weight"] = [kv*h, config.hidden_size] }
            shapes[p+"self_attn.o_proj.weight"] = [config.hidden_size, config.num_attention_heads*h]
            for n in ["q_norm", "k_norm"] { shapes[p+"self_attn.\(n).weight"] = [h] }
            for n in ["gate_proj", "up_proj"] { shapes[p+"mlp.\(n).weight"] = [config.intermediate_size, config.hidden_size] }
            shapes[p+"mlp.down_proj.weight"] = [config.hidden_size, config.intermediate_size]
            shapes[p+"ple_block.per_layer_input_gate.weight"] = [config.hidden_size_per_layer_input, config.hidden_size]
            shapes[p+"ple_block.per_layer_projection.weight"] = [config.hidden_size, config.hidden_size_per_layer_input]
        }
        weights = try WeightStore(loaded:selected,shapes:shapes,directory:directory,dtype:dtype)
    }

    private func linear(_ x: MLXArray, _ key: String) -> MLXArray {
        weights.linear(x,key+".weight")
    }
    private func norm(_ x: MLXArray, _ key: String? = nil) -> MLXArray {
        let f = x.asType(.float32)
        var y = f * rsqrt(mean(f * f, axis: -1, keepDims: true) + config.rms_norm_eps)
        if let key { y = y * weights[key+".weight"]!.asType(.float32) }
        return y.asType(x.dtype)
    }
    private func rotary(_ x: MLXArray, positions: MLXArray, theta: Float) -> MLXArray {
        let d = x.dim(-1), half = x.dim(-1)/2
        let frequencies = 1 / pow(MLXArray(theta), MLXArray(stride(from: 0, to: d, by: 2)).asType(.float32) / Float(d))
        let a = positions.asType(.float32).expandedDimensions(axis: -1) * frequencies
        let angles = concatenated([a,a], axis: -1).expandedDimensions(axis: 1)
        let rotated = concatenated([-x[.ellipsis, half...], x[.ellipsis, ..<half]], axis: -1)
        return x * cos(angles).asType(x.dtype) + rotated * sin(angles).asType(x.dtype)
    }
    public static func attentionMask(_ mask: MLXArray, length: Int, window: Int?) -> MLXArray {
        let full = mask.asType(.bool).reshaped(mask.dim(0), 1, 1, length)
        guard let window else { return full }
        let p = MLXArray(0..<length)
        return full .&& (abs(p.expandedDimensions(axis: 1) - p.expandedDimensions(axis: 0)) .<= window)
    }
    /// Returns projected per-token states and normalized sentence embeddings.
    public func encode(ids: [[Int]], mask: [[Int]], dimensions: Int = 768) throws -> (tokens: MLXArray, embeddings: MLXArray) {
        try encode(ids:ids,mask:mask,dimensions:dimensions,imageFeatures:nil)
    }
    func encode(ids: [[Int]], mask: [[Int]], dimensions: Int, imageFeatures: MLXArray?, mediaTokenID: Int = 258880) throws -> (tokens: MLXArray, embeddings: MLXArray) {
        guard [128,256,512,768].contains(dimensions), !ids.isEmpty, ids.count == mask.count,
              let length = ids.first?.count, length > 0, length <= 8192,
              ids.allSatisfy({ $0.count == length }), mask.allSatisfy({ $0.count == length && $0.contains(1) && $0.allSatisfy({ $0 == 0 || $0 == 1 }) }),
              ids.joined().allSatisfy({ $0 >= 0 && $0 < config.vocab_size && (![258880,258881,258884].contains($0) || ($0 == mediaTokenID && imageFeatures != nil)) }) else {
            throw EmbeddingError.invalid("Invalid text token batch, mask, context (1...8192), or dimensions")
        }
        let batch = ids.count
        let tokenIDs = MLXArray(ids.flatMap { $0.map { Int32($0 == mediaTokenID ? 0 : $0) } }).reshaped(batch,length)
        let padding = MLXArray(mask.flatMap { $0.map(Int32.init) }).reshaped(batch,length)
        var x = weights.embedding(tokenIDs,"embed_tokens.weight") * MLXArray(sqrt(Float(config.hidden_size))).asType(dtype)
        if let imageFeatures {
            let flat = ids.flatMap { $0 }
            let count = flat.filter { $0 == mediaTokenID }.count
            guard count > 0, imageFeatures.shape == [count,config.hidden_size] else { throw EmbeddingError.invalid("Media token/feature count mismatch") }
            var index = 0
            let indices = flat.map { id -> Int32 in
                if id == mediaTokenID { defer { index += 1 }; return Int32(index) }
                return 0
            }
            let features = imageFeatures[MLXArray(indices)].reshaped(batch,length,config.hidden_size)
            let slots = MLXArray(flat.map { Int32($0 == mediaTokenID ? 1 : 0) }).asType(.bool).reshaped(batch,length,1)
            x = which(slots,features.asType(dtype),x)
        }
        let projected = (linear(x,"ple.per_layer_model_projection") * (1 / sqrt(Float(config.hidden_size)))).reshaped(batch,length,config.num_hidden_layers,config.hidden_size_per_layer_input)
        let perLayer = norm(projected, "ple.per_layer_projection_norm")
        let positions = MLXArray(0..<length).reshaped(1,length)
        let full = Self.attentionMask(padding,length:length,window:nil)
        let local = Self.attentionMask(padding,length:length,window:config.sliding_window)
        for i in 0..<config.num_hidden_layers {
            let p = "layers.\(i).", a = p+"self_attn."
            let override = config.per_layer_config[String(format:"%02d",i)] ?? [:]
            let h = override["head_dim"] ?? config.head_dim, kv = override["num_key_value_heads"] ?? config.num_key_value_heads
            let kind = config.layer_types[i]
            let theta = config.rope_parameters[kind]!.rope_theta
            let z = norm(x,p+"input_layernorm")
            let q = rotary(norm(linear(z,a+"q_proj").reshaped(batch,length,config.num_attention_heads,h),a+"q_norm").transposed(0,2,1,3),positions:positions,theta:theta)
            let k = rotary(norm(linear(z,a+"k_proj").reshaped(batch,length,kv,h),a+"k_norm").transposed(0,2,1,3),positions:positions,theta:theta)
            let v = norm(linear(z,a+"v_proj").reshaped(batch,length,kv,h)).transposed(0,2,1,3)
            let attended = MLXFast.scaledDotProductAttention(queries:q,keys:k,values:v,scale:1,mask:.array(kind == "sliding_attention" ? local : full)).transposed(0,2,1,3).reshaped(batch,length,-1)
            x = x + norm(linear(attended,a+"o_proj"),p+"post_attention_layernorm")
            let f = norm(x,p+"pre_feedforward_layernorm")
            x = x + norm(linear(geluApproximate(linear(f,p+"mlp.gate_proj")) * linear(f,p+"mlp.up_proj"),p+"mlp.down_proj"),p+"post_feedforward_layernorm")
            let gate = geluApproximate(linear(x,p+"ple_block.per_layer_input_gate")) * perLayer[0...,0...,i,0...]
            x = (x + norm(linear(gate,p+"ple_block.per_layer_projection"),p+"ple_block.post_per_layer_input_norm")) * weights[p+"layer_scalar"]!
        }
        let tokens = linear(norm(x,"norm"),"embedding_projection")
        let m = padding.asType(.float32).expandedDimensions(axis:-1)
        let pooled = sum(tokens.asType(.float32)*m,axis:1) / sum(m,axis:1)
        let truncated = pooled[0...,..<dimensions]
        let embeddings = truncated / maximum(sqrt(sum(truncated*truncated,axis:-1,keepDims:true)),1e-12)
        eval(embeddings)
        return (tokens,embeddings)
    }
}
