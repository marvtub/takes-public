import Foundation
import MLX
import MLXNN

/// Pinned Gemma4 Conformer; follows the official Transformers masking, including padded queries.
final class AudioModel {
    let dtype: DType
    private let weights: [String:MLXArray]
    private let clips: [String:(Float,Float,Float,Float)]
    init(directory:URL,float32:Bool) throws {
        let root=try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("config.json"))) as? [String:Any]
        guard let c=root?["audio_config"] as? [String:Any], c["model_type"] as? String == "gemma4_audio",
              c["hidden_size"] as? Int == 1024, c["num_hidden_layers"] as? Int == 12,
              c["num_attention_heads"] as? Int == 8, c["attention_chunk_size"] as? Int == 12,
              c["attention_context_left"] as? Int == 13, c["attention_context_right"] as? Int == 0,
              c["conv_kernel_size"] as? Int == 5, c["output_proj_dims"] as? Int == 1536,
              c["subsampling_conv_channels"] as? [Int] == [128,32], c["use_clipped_linears"] as? Bool == true,
              c["residual_weight"] as? Double == 0.5, c["rms_norm_eps"] as? Double == 1e-6,
              c["attention_logit_cap"] as? Double == 50, c["attention_invalid_logits_value"] as? Double == -1e9,
              c["gradient_clipping"] as? Double == 1e10, c["hidden_act"] as? String == "silu" else {
            throw EmbeddingError.invalid("Unsupported audio configuration")
        }
        dtype=float32 ? .float32:.bfloat16
        let loaded=try MLX.loadArrays(url:directory.appendingPathComponent("audio.safetensors"))
        var shapes:[String:[Int]]=["audio_tower.subsample_conv_projection.layer0.conv.weight":[128,1,3,3],"audio_tower.subsample_conv_projection.layer0.norm.weight":[128],"audio_tower.subsample_conv_projection.layer1.conv.weight":[32,128,3,3],"audio_tower.subsample_conv_projection.layer1.norm.weight":[32],"audio_tower.subsample_conv_projection.input_proj_linear.weight":[1024,1024],"audio_tower.output_proj.weight":[1536,1024],"audio_tower.output_proj.bias":[1536],"embed_audio.embedding_projection.weight":[512,1536]]
        var clippedNames=[String]()
        func clipped(_ name:String,_ out:Int,_ input:Int) {
            clippedNames.append(name);shapes[name+".linear.weight"]=[out,input]
            for bound in ["input_min","input_max","output_min","output_max"] { shapes[name+"."+bound]=[] }
        }
        for i in 0..<12 {
            let p="audio_tower.layers.\(i)."
            for f in ["feed_forward1.","feed_forward2."] {
                clipped(p+f+"ffw_layer_1",4096,1024);clipped(p+f+"ffw_layer_2",1024,4096)
                shapes[p+f+"pre_layer_norm.weight"]=[1024];shapes[p+f+"post_layer_norm.weight"]=[1024]
            }
            for n in ["q_proj","k_proj","v_proj","post"] { clipped(p+"self_attn."+n,1024,1024) }
            shapes[p+"self_attn.relative_k_proj.weight"]=[1024,1024];shapes[p+"self_attn.per_dim_scale"]=[128]
            clipped(p+"lconv1d.linear_start",2048,1024);clipped(p+"lconv1d.linear_end",1024,1024)
            shapes[p+"lconv1d.depthwise_conv1d.weight"]=[1024,1,5]
            for n in ["lconv1d.pre_layer_norm","lconv1d.conv_norm","norm_pre_attn","norm_post_attn","norm_out"] { shapes[p+n+".weight"]=[1024] }
        }
        guard Set(shapes.keys)==Set(loaded.keys) else { throw EmbeddingError.invalid("Audio weight keys mismatch") }
        var selected=[String:MLXArray]()
        for (name,shape) in shapes {
            let value=loaded[name]!
            guard value.shape==shape, value.dtype == .bfloat16 || value.dtype == .float32 else { throw EmbeddingError.invalid("Unsupported audio tensor: \(name)") }
            if !shape.isEmpty {
                var tensor=value.asType(dtype)
                if name.contains(".conv.weight") { tensor=tensor.transposed(0,2,3,1) }
                if name.contains("depthwise_conv1d.weight") { tensor=tensor.transposed(0,2,1) }
                selected[name]=tensor
            }
        }
        var bounds=[String:(Float,Float,Float,Float)]()
        for name in clippedNames {
            bounds[name]=(loaded[name+".input_min"]!.item(Float.self),loaded[name+".input_max"]!.item(Float.self),loaded[name+".output_min"]!.item(Float.self),loaded[name+".output_max"]!.item(Float.self))
        }
        clips=bounds;weights=selected;eval(Array(weights.values))
    }
    private func linear(_ x:MLXArray,_ name:String) -> MLXArray { matmul(x,weights[name+".weight"]!.T) }
    private func clinear(_ x:MLXArray,_ name:String) -> MLXArray {
        let (a,b,c,d)=clips[name]!
        return clip(linear(clip(x,min:a,max:b),name+".linear"),min:c,max:d)
    }
    private func norm(_ x:MLXArray,_ name:String? = nil,centered:Bool = false) -> MLXArray {
        var f=x.asType(.float32)
        if centered { f=f-mean(f,axis:-1,keepDims:true) }
        var y=f*rsqrt(mean(f*f,axis:-1,keepDims:true)+1e-6)
        if let name { y=y*weights[name+".weight"]!.asType(.float32) }
        return y.asType(x.dtype)
    }
    private func ff(_ x:MLXArray,_ p:String) -> MLXArray {
        var f=norm(clip(x,min:Float(-1e10),max:Float(1e10)),p+"pre_layer_norm")
        f=clinear(silu(clinear(f,p+"ffw_layer_1")),p+"ffw_layer_2")
        return x+norm(clip(f,min:Float(-1e10),max:Float(1e10)),p+"post_layer_norm")*0.5
    }
    private func attention(_ x:MLXArray,_ p:String,mask:[Int32]) -> MLXArray {
        let n=x.dim(1),blocks=(n+11)/12,total=blocks*12
        var q=clinear(x,p+"q_proj").asType(.float32).reshaped(1,n,8,128)
        let qScale=Float(pow(128.0,-0.5)/log(2.0)),kScale=Float(log(1+exp(1.0))/log(2.0))
        q=q*qScale*softplus(weights[p+"per_dim_scale"]!)
        let k=(clinear(x,p+"k_proj").asType(.float32)*kScale).reshaped(1,n,8,128)
        let v=clinear(x,p+"v_proj").asType(.float32).reshaped(1,n,8,128)
        q=padded(q,widths:[0,IntOrPair((0,total-n)),0,0]).reshaped(1,blocks,12,8,128).transposed(0,3,1,2,4)
        let indices=MLXArray((0..<blocks).flatMap { b in (0..<24).map { Int32(b*12+$0) } }).reshaped(blocks,24)
        let key=padded(k,widths:[0,IntOrPair((12,11)),0,0])[0...,indices].transposed(0,3,1,4,2)
        let value=padded(v,widths:[0,IntOrPair((12,11)),0,0])[0...,indices].transposed(0,3,1,2,4)
        let freq=exp(MLXArray(0..<512).asType(.float32)*Float(-log(10000.0)/511))
        let pos=MLXArray(stride(from:12,through:0,by:-1)).asType(.float32).reshaped(13,1)*freq
        let rel=linear(concatenated([sin(pos),cos(pos)],axis:-1).asType(dtype),p+"relative_k_proj").reshaped(13,8,128).asType(.float32).transposed(1,2,0)
        var bd=matmul(q.reshaped(1,8,total,128),rel).reshaped(1,8,blocks,12,13)
        bd=padded(bd,widths:[0,0,0,0,IntOrPair((0,12))]).reshaped(1,8,blocks,300)[.ellipsis,..<288].reshaped(1,8,blocks,12,24)
        var logits=tanh((matmul(q,key)+bd)/50)*50
        let allowed=(0..<blocks).flatMap { b in (0..<12).flatMap { row in (0..<24).map { column -> Int32 in
            let query=b*12+row,key=b*12+column-12,dist=query-key
            return query<n && key>=0 && key<n && mask[key]==1 && dist>=0 && dist<12 ? 1:0
        } } }
        let condition=MLXArray(allowed).asType(.bool).reshaped(1,1,blocks,12,24)
        logits=which(condition,logits,MLXArray(Float(-1e9)))
        let out=matmul(softmax(logits,axis:-1,precise:true),value).transposed(0,2,3,1,4).reshaped(1,total,1024)[0...,..<n,0...]
        return clinear(out.asType(dtype),p+"post")
    }
    func encode(_ audio:PreparedAudio) -> MLXArray {
        var mask=audio.mask
        var x=MLXArray(audio.features).reshaped(1,audio.frames,128,1).asType(dtype)
        for i in 0..<2 {
            let p="audio_tower.subsample_conv_projection.layer\(i)."
            x=x*MLXArray(mask).asType(dtype).reshaped(1,mask.count,1,1)
            x=conv2d(x,weights[p+"conv.weight"]!,stride:2,padding:1)
            x=maximum(norm(x,p+"norm",centered:true),0)
            mask=stride(from:0,to:mask.count,by:2).map { mask[$0] }
        }
        x=linear(x.reshaped(1,mask.count,1024),"audio_tower.subsample_conv_projection.input_proj_linear")
        for i in 0..<12 {
            let p="audio_tower.layers.\(i)."
            x=ff(x,p+"feed_forward1.")
            let a=attention(norm(clip(x,min:Float(-1e10),max:Float(1e10)),p+"norm_pre_attn"),p+"self_attn.",mask:mask)
            x=x+norm(clip(a,min:Float(-1e10),max:Float(1e10)),p+"norm_post_attn")
            let residual=x,c=p+"lconv1d."
            var z=clinear(norm(x,c+"pre_layer_norm"),c+"linear_start")
            z=z[.ellipsis,..<1024]*sigmoid(z[.ellipsis,1024...])
            z=conv1d(padded(z,widths:[0,IntOrPair((4,0)),0]),weights[c+"depthwise_conv1d.weight"]!,groups:1024)
            z=norm(clip(z,min:Float(-1e10),max:Float(1e10)),c+"conv_norm")
            x=residual+clinear(silu(z),c+"linear_end")
            x=ff(x,p+"feed_forward2.")
            x=norm(clip(x,min:Float(-1e10),max:Float(1e10)),p+"norm_out")
        }
        x=linear(x,"audio_tower.output_proj")+weights["audio_tower.output_proj.bias"]!
        let features=linear(norm(x),"embed_audio.embedding_projection")[0,MLXArray(mask.enumerated().filter { $0.element==1 }.map { Int32($0.offset) })]
        eval(features);return features
    }
}
