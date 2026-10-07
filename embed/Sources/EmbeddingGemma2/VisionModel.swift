import Foundation
import MLX
import MLXNN

struct VisionConfiguration: Decodable {
    let model_type: String
    let hidden_size, intermediate_size, num_hidden_layers, num_attention_heads, num_key_value_heads, head_dim: Int
    let patch_size, pooling_kernel_size, position_embedding_size: Int
    let rms_norm_eps: Float
    let standardize, use_clipped_linears: Bool
    let rope_parameters: TextConfiguration.RopeConfiguration
}

/// One image at a time. Padding patches are removed before attention; valid patches cannot attend to them.
final class VisionModel {
    let config: VisionConfiguration
    let dtype: DType
    private let weights: WeightStore
    init(directory: URL, float32: Bool) throws {
        struct Wrapper: Decodable { let vision_config: VisionConfiguration }
        config = try JSONDecoder().decode(Wrapper.self,from:Data(contentsOf:directory.appendingPathComponent("config.json"))).vision_config
        guard config.model_type == "gemma4_vision", config.hidden_size == 768, config.intermediate_size == 3072,
              config.num_hidden_layers == 16, config.num_attention_heads == 12, config.num_key_value_heads == 12,
              config.head_dim == 64, config.patch_size == 16, config.pooling_kernel_size == 3,
              config.position_embedding_size == 10240, !config.standardize, !config.use_clipped_linears,
              config.rope_parameters.rope_type == "axial", config.rope_parameters.rope_theta == 100 else {
            throw EmbeddingError.invalid("Unsupported vision configuration")
        }
        dtype = float32 ? .float32 : .bfloat16
        let loaded = try MLX.loadArrays(url:directory.appendingPathComponent("vision.safetensors"))
        var shapes: [String:[Int]] = [
            "vision_tower.patch_embedder.input_proj.weight":[768,768],
            "vision_tower.patch_embedder.position_embedding_table":[2,10240,768],
            "embed_vision.embedding_projection.weight":[512,768]]
        for i in 0..<16 {
            let p = "vision_tower.encoder.layers.\(i)."
            for n in ["input_layernorm","post_attention_layernorm","pre_feedforward_layernorm","post_feedforward_layernorm"] { shapes[p+n+".weight"] = [768] }
            for n in ["q_proj","k_proj","v_proj","o_proj"] { shapes[p+"self_attn."+n+".linear.weight"] = [768,768] }
            for n in ["q_norm","k_norm"] { shapes[p+"self_attn."+n+".weight"] = [64] }
            for n in ["gate_proj","up_proj"] { shapes[p+"mlp."+n+".linear.weight"] = [3072,768] }
            shapes[p+"mlp.down_proj.linear.weight"] = [768,3072]
        }
        weights = try WeightStore(loaded:loaded,shapes:shapes,directory:directory,dtype:dtype)
    }
    private func linear(_ x: MLXArray,_ name: String) -> MLXArray { weights.linear(x,name+".weight") }
    private func norm(_ x: MLXArray,_ name: String? = nil) -> MLXArray {
        let f = x.asType(.float32)
        var y = f * rsqrt(mean(f*f,axis:-1,keepDims:true)+config.rms_norm_eps)
        if let name { y = y * weights[name+".weight"]!.asType(.float32) }
        return y.asType(x.dtype)
    }
    private func rotary(_ x: MLXArray,positions: MLXArray) -> MLXArray {
        let frequency = 1 / pow(MLXArray(config.rope_parameters.rope_theta),MLXArray(stride(from:0,to:32,by:2)).asType(.float32)/32)
        var parts = [MLXArray]()
        for axis in 0..<2 {
            let part = x[.ellipsis,(axis*32)..<((axis+1)*32)]
            let angles = positions[0...,0...,axis].asType(.float32).expandedDimensions(axis:-1)*frequency
            let doubled = concatenated([angles,angles],axis:-1).expandedDimensions(axis:2)
            let rotated = concatenated([-part[.ellipsis,16...],part[.ellipsis,..<16]],axis:-1)
            parts.append(part*cos(doubled).asType(dtype)+rotated*sin(doubled).asType(dtype))
        }
        return concatenated(parts,axis:-1)
    }
    func encode(_ image: PreparedImage) -> MLXArray {
        let n = image.patchCount, pw = image.width/16, ph = image.height/16
        let pixels = MLXArray(Array(image.pixels.prefix(n*768))).reshaped(1,n,768)
        let positions = MLXArray(Array(image.positions.prefix(n*2))).reshaped(1,n,2)
        let table = weights["vision_tower.patch_embedder.position_embedding_table"]!
        var x = linear((2*(pixels-0.5)).asType(dtype),"vision_tower.patch_embedder.input_proj")
        x = x + table[0][positions[0...,0...,0]] + table[1][positions[0...,0...,1]]
        for i in 0..<16 {
            let p = "vision_tower.encoder.layers.\(i).", a = p+"self_attn."
            let z = norm(x,p+"input_layernorm")
            let q = rotary(norm(linear(z,a+"q_proj.linear").reshaped(1,n,12,64),a+"q_norm"),positions:positions).transposed(0,2,1,3)
            let k = rotary(norm(linear(z,a+"k_proj.linear").reshaped(1,n,12,64),a+"k_norm"),positions:positions).transposed(0,2,1,3)
            let v = norm(linear(z,a+"v_proj.linear").reshaped(1,n,12,64)).transposed(0,2,1,3)
            let attended = MLXFast.scaledDotProductAttention(queries:q,keys:k,values:v,scale:1,mask:.none).transposed(0,2,1,3).reshaped(1,n,768)
            x = x + norm(linear(attended,a+"o_proj.linear"),p+"post_attention_layernorm")
            let f = norm(x,p+"pre_feedforward_layernorm")
            x = x + norm(linear(geluApproximate(linear(f,p+"mlp.gate_proj.linear"))*linear(f,p+"mlp.up_proj.linear"),p+"mlp.down_proj.linear"),p+"post_feedforward_layernorm")
        }
        // The upstream pooler accumulates in FP32, casts to working dtype, then scales in FP32.
        let pooled = mean(x.asType(.float32).reshaped(1,ph/3,3,pw/3,3,768),axes:[2,4]).reshaped(image.softTokenCount,768).asType(dtype)
        let scaled = (pooled.asType(.float32)*sqrt(Float(768))).asType(dtype)
        let features = linear(norm(scaled),"embed_vision.embedding_projection")
        eval(features)
        return features
    }
}
