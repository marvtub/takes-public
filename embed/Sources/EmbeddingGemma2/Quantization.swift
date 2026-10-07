import Foundation
import CryptoKit
import MLX

struct QuantizationMetadata: Codable {
    let version: Int
    let mode: String
    let bits, groupSize: Int
    let shapes: [String:[Int]]
    static func load(_ directory:URL) throws -> Self? {
        let url=directory.appendingPathComponent("quantization.json")
        guard FileManager.default.fileExists(atPath:url.path) else { return nil }
        let q=try JSONDecoder().decode(Self.self,from:Data(contentsOf:url))
        guard q.version==1,q.mode=="affine",[4,8].contains(q.bits),q.groupSize==64,!q.shapes.isEmpty else { throw EmbeddingError.invalid("Unsupported quantization metadata") }
        return q
    }
}

/// Keeps packed matrices resident; only requested embedding rows are dequantized.
struct WeightStore {
    let values: [String:MLXArray]
    let quantization: QuantizationMetadata?
    let dtype: DType
    init(loaded:[String:MLXArray], shapes:[String:[Int]], directory:URL, dtype:DType) throws {
        self.dtype=dtype
        let q=try QuantizationMetadata.load(directory);quantization=q
        let packed=q?.shapes ?? [:]
        guard Set(packed.keys).isSubset(of:Set(shapes.keys)) else { throw EmbeddingError.invalid("Unknown quantized tensors") }
        var keys=Set(shapes.keys),selected=[String:MLXArray]()
        for key in packed.keys { keys.insert(key+".scales");keys.insert(key+".biases") }
        guard Set(loaded.keys)==keys else { throw EmbeddingError.invalid("Weight keys mismatch") }
        for (key,shape) in shapes {
            let value=loaded[key]!
            if let original=packed[key],let q {
                guard original==shape,shape.count==2,shape[1]%q.groupSize==0,
                      value.shape==[shape[0],shape[1]*q.bits/32],value.dtype == .uint32 else { throw EmbeddingError.invalid("Invalid packed tensor: \(key)") }
                selected[key]=value
                for suffix in [".scales",".biases"] {
                    let a=loaded[key+suffix]!
                    guard a.shape==[shape[0],shape[1]/q.groupSize],a.dtype == .bfloat16 || a.dtype == .float32 else { throw EmbeddingError.invalid("Invalid quantization scales/biases: \(key)") }
                    selected[key+suffix]=a.asType(dtype)
                }
            } else {
                guard value.shape==shape,value.dtype == .bfloat16 || value.dtype == .float32 else { throw EmbeddingError.invalid("Invalid tensor shape/precision: \(key)") }
                selected[key]=value.asType(dtype)
            }
        }
        values=selected;eval(Array(selected.values))
    }
    subscript(_ key:String) -> MLXArray? { values[key] }
    func linear(_ x:MLXArray,_ key:String) -> MLXArray {
        if let q=quantization,q.shapes[key] != nil {
            return quantizedMM(x,values[key]!,scales:values[key+".scales"]!,biases:values[key+".biases"]!,transpose:true,groupSize:q.groupSize,bits:q.bits)
        }
        return matmul(x,values[key]!.T)
    }
    func embedding(_ ids:MLXArray,_ key:String) -> MLXArray {
        if let q=quantization,let shape=q.shapes[key] {
            let rows=ids.reshaped(-1)
            return dequantized(values[key]![rows],scales:values[key+".scales"]![rows],biases:values[key+".biases"]![rows],groupSize:q.groupSize,bits:q.bits,dtype:dtype).reshaped(ids.shape+[shape[1]])
        }
        return values[key]![ids]
    }
    var format:String { quantization.map { "affine\($0.bits)-g\($0.groupSize)" } ?? "unquantized" }
}

public enum QuantizedCheckpoint {
    /// Standard MLX affine PTQ. Never overwrites a checkpoint or quantizes a quantized source.
    public static func convert(source:URL,destination:URL,bits:Int) throws {
        let fm=FileManager.default
        guard [4,8].contains(bits),!fm.fileExists(atPath:destination.path),try QuantizationMetadata.load(source)==nil else { throw EmbeddingError.invalid("Expected new destination, original source, and 4 or 8 bits") }
        let name: String
        if fm.fileExists(atPath:source.appendingPathComponent("vision.safetensors").path) { name="vision.safetensors" }
        else if fm.fileExists(atPath:source.appendingPathComponent("model.safetensors").path) { name="model.safetensors" }
        else { throw EmbeddingError.invalid("Expected extracted text or vision checkpoint") }
        let url=source.appendingPathComponent(name)
        let original=try MLX.loadArrays(url:url)
        var output=[String:MLXArray](),shapes=[String:[Int]]()
        for key in original.keys.sorted() {
            let w=original[key]!
            guard w.dtype == .bfloat16 || w.dtype == .float32 else { throw EmbeddingError.invalid("Source must be BF16/FP32") }
            if key.hasSuffix(".weight"),w.ndim==2,w.dim(1)%64==0,w.dim(0)%32==0 {
                let (packed,scales,biases)=quantized(w,groupSize:64,bits:bits)
                guard let biases else { throw EmbeddingError.invalid("Expected affine biases") }
                eval(packed,scales,biases)
                output[key]=packed;output[key+".scales"]=scales;output[key+".biases"]=biases;shapes[key]=w.shape
            } else { output[key]=w }
        }
        guard !shapes.isEmpty else { throw EmbeddingError.invalid("No compatible matrices") }
        // Build in a sibling temporary directory, then rename only after every file is ready.
        let staging=destination.deletingLastPathComponent().appendingPathComponent(".quantize-"+UUID().uuidString)
        try fm.createDirectory(at:staging,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:staging) }
        try MLX.save(arrays:output,url:staging.appendingPathComponent(name))
        for f in ["config.json","tokenizer.json","tokenizer_config.json","config_sentence_transformers.json"] where fm.fileExists(atPath:source.appendingPathComponent(f).path) {
            try fm.copyItem(at:source.appendingPathComponent(f),to:staging.appendingPathComponent(f))
        }
        // Text runtime stores local names, so metadata uses those same names.
        let names=Dictionary(uniqueKeysWithValues:shapes.map { key,value in (key.hasPrefix("language_model.") ? String(key.dropFirst(15)):key,value) })
        let metadata=QuantizationMetadata(version:1,mode:"affine",bits:bits,groupSize:64,shapes:names)
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(metadata).write(to:staging.appendingPathComponent("quantization.json"))
        func hash(_ url:URL) throws -> String {
            let file=try FileHandle(forReadingFrom:url);defer { try? file.close() };var sha=SHA256()
            while let bytes=try file.read(upToCount:1024*1024),!bytes.isEmpty { sha.update(data:bytes) }
            return sha.finalize().map { String(format:"%02x",$0) }.joined()
        }
        let manifest:[String:Any]=["source_sha256":try hash(url),"output_sha256":try hash(staging.appendingPathComponent(name)),"weight_file":name,"bits":bits,"group_size":64,"quantized_matrices":shapes.count,"mlx_swift":"0.32.3","method":"standard MLX affine; all compatible 2D weight matrices"]
        try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]).write(to:staging.appendingPathComponent("manifest.json"))
        try fm.moveItem(at:staging,to:destination)
    }
}
