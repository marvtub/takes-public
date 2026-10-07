import Foundation

public struct PreparedAudio: Sendable {
    public let features: [Float]
    public let mask: [Int32]
    public let sampleCount: Int
    public var frames: Int { mask.count }
    public var softTokenCount: Int { stride(from:0,to:mask.count,by:4).reduce(0) { $0+Int(mask[$1]) } }
}

public enum AudioProcessor {
    /// Strict RIFF PCM16 mono / 16kHz input. Resample/downmix explicitly before calling.
    public static func loadWAV(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf:url,options:.mappedIfSafe)
        guard data.count >= 44, data.count <= 2_000_000 else { throw EmbeddingError.invalid("WAV size is invalid or exceeds clip limit") }
        func u16(_ i:Int) -> Int { Int(data[i]) | Int(data[i+1])<<8 }
        func u32(_ i:Int) -> Int { u16(i) | u16(i+2)<<16 }
        func tag(_ i:Int) -> String { String(decoding:data[i..<i+4],as:UTF8.self) }
        guard tag(0)=="RIFF", tag(8)=="WAVE" else { throw EmbeddingError.invalid("Expected RIFF WAV") }
        var offset=12, validFormat=false, payload:Range<Int>?
        while offset+8 <= data.count {
            let length=u32(offset+4),start=offset+8
            guard length <= data.count-start else { throw EmbeddingError.invalid("Truncated WAV chunk") }
            if tag(offset)=="fmt " {
                guard length>=16, u16(start)==1, u16(start+2)==1, u32(start+4)==16000, u16(start+12)==2, u16(start+14)==16 else {
                    throw EmbeddingError.invalid("Only mono 16kHz PCM16 WAV is supported; resample/downmix explicitly")
                }
                validFormat=true
            } else if tag(offset)=="data" { payload=start..<start+length }
            offset=start+length+(length%2)
        }
        guard validFormat, let payload, payload.count%2==0 else { throw EmbeddingError.invalid("Missing WAV PCM data") }
        let samples=stride(from:payload.lowerBound,to:payload.upperBound,by:2).map { Float(Int16(bitPattern:UInt16(u16($0))))/32768 }
        guard (161...480000).contains(samples.count) else { throw EmbeddingError.invalid("Audio must contain 161...480000 samples (up to 30 seconds)") }
        return samples
    }
    private static let window=(0..<320).map { Float(0.5-0.5*cos(2*Double.pi*Double($0)/320)) }
    private static let filters: [[Double]] = {
        let maxMel=2595*log10(1+8000.0/700)
        let frequencies=(0..<130).map { 700*(pow(10,Double($0)*maxMel/129/2595)-1) }
        return (0..<257).map { bin in
            let hz=Double(bin)*16000/512
            return (0..<128).map { i in max(0,min((hz-frequencies[i])/(frequencies[i+1]-frequencies[i]),(frequencies[i+2]-hz)/(frequencies[i+2]-frequencies[i+1]))) }
        }
    }()
    /// Radix-2 FFT in Double, rounded to the reference complex64 spectrum before magnitude.
    private static func magnitude(_ frame:[Float]) -> [Double] {
        var re=frame.map(Double.init)+Array(repeating:0.0,count:512-frame.count),im=[Double](repeating:0,count:512)
        var j=0
        for i in 1..<512 {
            var bit=256
            while j & bit != 0 { j ^= bit; bit >>= 1 }; j ^= bit
            if i<j { re.swapAt(i,j); im.swapAt(i,j) }
        }
        var size=2
        while size<=512 {
            for start in stride(from:0,to:512,by:size) {
                for k in 0..<size/2 {
                    let angle = -2*Double.pi*Double(k)/Double(size),c=cos(angle),s=sin(angle)
                    let i=start+k,j=i+size/2,vr=re[j]*c-im[j]*s,vi=re[j]*s+im[j]*c
                    re[j]=re[i]-vr; im[j]=im[i]-vi; re[i]+=vr; im[i]+=vi
                }
            }; size*=2
        }
        return (0..<257).map { Double(hypot(Float(re[$0]),Float(im[$0]))) }
    }
    public static func prepare(samples:[Float], sampleRate:Int = 16000) throws -> PreparedAudio {
        guard sampleRate==16000, (161...480000).contains(samples.count), samples.allSatisfy({ $0.isFinite && abs($0)<=1 }) else {
            throw EmbeddingError.invalid("Expected finite mono16kHz samples in [-1,1], length161...480000")
        }
        let paddedCount=((samples.count+127)/128)*128,frames=(paddedCount-161)/160+1
        var output=[Float](repeating:0,count:frames*128),mask=[Int32](repeating:0,count:frames)
        for t in 0..<frames {
            guard t*160+160 < samples.count else { continue }
            mask[t]=1
            let frame=(0..<320).map { i -> Float in
                let index=t*160+i-160
                return (index>=0 && index<samples.count ? samples[index] : 0)*window[i]
            }
            let spectrum=magnitude(frame)
            for mel in 0..<128 {
                var value=0.0
                for bin in 0..<257 { value+=spectrum[bin]*filters[bin][mel] }
                output[t*128+mel]=Float(log(value+0.001))
            }
        }
        return PreparedAudio(features:output,mask:mask,sampleCount:samples.count)
    }
}
