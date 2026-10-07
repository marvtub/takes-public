import Foundation
import CoreGraphics
import ImageIO

public struct RGBImage: Sendable {
    public let width: Int
    public let height: Int
    public let bytes: [UInt8]
    public init(width: Int, height: Int, bytes: [UInt8]) throws {
        guard width > 0, height > 0, width <= 20000, height <= 20000,
              width * height <= 40_000_000, bytes.count == width * height * 3 else {
            throw EmbeddingError.invalid("Expected RGB8 image, positive dimensions and at most 40 megapixels")
        }
        self.width = width; self.height = height; self.bytes = bytes
    }
    /// Decodes opaque images to sRGB and applies EXIF orientation. Transparent images must be flattened explicitly.
    public static func load(_ url: URL) throws -> RGBImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20000, height <= 20000, width * height <= 40_000_000,
              let image = CGImageSourceCreateImageAtIndex(source,0,nil) else {
            throw EmbeddingError.invalid("Cannot decode image or image exceeds 40 megapixels")
        }
        var rgba = [UInt8](repeating:0,count:width*height*4)
        let drawn = rgba.withUnsafeMutableBytes { pointer -> Bool in
            guard let context = CGContext(data:pointer.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image,in:CGRect(x:0,y:0,width:width,height:height)); return true
        }
        guard drawn else { throw EmbeddingError.invalid("Cannot allocate image decoder") }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        guard (1...8).contains(orientation) else { throw EmbeddingError.invalid("Invalid EXIF orientation") }
        let w = orientation >= 5 ? height : width, h = orientation >= 5 ? width : height
        var rgb = [UInt8](repeating:0,count:w*h*3)
        for y in 0..<height { for x in 0..<width {
            let offset = (y*width+x)*4
            guard rgba[offset+3] == 255 else { throw EmbeddingError.invalid("Transparent image: flatten to opaque RGB before encoding") }
            let destination: (Int,Int)
            switch orientation {
            case 2: destination = (width-1-x,y)
            case 3: destination = (width-1-x,height-1-y)
            case 4: destination = (x,height-1-y)
            case 5: destination = (y,x)
            case 6: destination = (height-1-y,x)
            case 7: destination = (height-1-y,width-1-x)
            case 8: destination = (y,width-1-x)
            default: destination = (x,y)
            }
            for c in 0..<3 { rgb[(destination.1*w+destination.0)*3+c] = rgba[offset+c] }
        }}
        return try RGBImage(width:w,height:h,bytes:rgb)
    }
}

public struct PreparedImage: Sendable {
    public let pixels: [Float]
    public let positions: [Int32]
    public let resizedRGB: [UInt8]
    public let width, height, maxSoftTokens: Int
    public var patchCount: Int { width / 16 * (height / 16) }
    public var softTokenCount: Int { patchCount / 9 }
}

public enum ImageProcessor {
    public static func targetSize(width: Int, height: Int, maxSoftTokens: Int = 280) throws -> (width:Int,height:Int) {
        guard [70,140,280].contains(maxSoftTokens), width > 0, height > 0, width <= 20000, height <= 20000 else {
            throw EmbeddingError.invalid("Image budget must be 70, 140 or 280; dimensions must be 1...20000")
        }
        let factor = sqrt(Double(maxSoftTokens*9*256) / (Double(width)*Double(height)))
        var w = Int(floor(factor*Double(width)/48))*48
        var h = Int(floor(factor*Double(height)/48))*48
        if h == 0 { h = 48; w = min((width/height)*48,maxSoftTokens*48) }
        if w == 0 { w = 48; h = min((height/width)*48,maxSoftTokens*48) }
        guard w > 0, h > 0, w*h <= maxSoftTokens*9*256 else { throw EmbeddingError.invalid("Invalid resized image dimensions") }
        return (w,h)
    }
    // Pillow 12.0 bicubic (a=-0.5), antialias support and 22-bit integer coefficients.
    // Adapted from libImaging/Resample.c; see UPSTREAM_PILLOW_LICENSE.
    private static func coefficients(input: Int, output: Int) -> [(start:Int, weights:[Int])] {
        let scale = Double(input)/Double(output), filterScale = max(1,scale)
        let support = 2*filterScale
        return (0..<output).map { i in
            let center = (Double(i)+0.5)*scale
            let start = max(0,Int(center-support+0.5)), end = min(input,Int(center+support+0.5))
            let weights = (start..<end).map { j -> Double in
                let x = abs((Double(j)-center+0.5)/filterScale)
                if x < 1 { return ((1.5*x-2.5)*x*x+1) }
                if x < 2 { return (((x-5)*x+8)*x-4) * -0.5 }
                return 0
            }
            let total = weights.reduce(0,+)
            return (start,weights.map { weight in
                let value = weight/total * Double(1<<22)
                return Int(value + (value < 0 ? -0.5 : 0.5))
            })
        }
    }
    public static func resize(_ image: RGBImage, width: Int, height: Int) throws -> RGBImage {
        guard width > 0, height > 0, width <= 20000, height <= 20000, width*height <= 40_000_000 else { throw EmbeddingError.invalid("Invalid resize target") }
        var horizontal = image.bytes
        if width != image.width {
            let coefficients = coefficients(input:image.width,output:width)
            horizontal = [UInt8](repeating:0,count:width*image.height*3)
            for y in 0..<image.height { for x in 0..<width { for c in 0..<3 {
                let entry = coefficients[x]
                var value = 1<<21
                for (j,weight) in entry.weights.enumerated() { value += Int(image.bytes[(y*image.width+entry.start+j)*3+c])*weight }
                horizontal[(y*width+x)*3+c] = UInt8(clamping:value>>22)
            }}}
        }
        var output = horizontal
        if height != image.height {
            let coefficients = coefficients(input:image.height,output:height)
            output = [UInt8](repeating:0,count:width*height*3)
            for y in 0..<height { for x in 0..<width { for c in 0..<3 {
                let entry = coefficients[y]
                var value = 1<<21
                for (j,weight) in entry.weights.enumerated() { value += Int(horizontal[((entry.start+j)*width+x)*3+c])*weight }
                output[(y*width+x)*3+c] = UInt8(clamping:value>>22)
            }}}
        }
        return try RGBImage(width:width,height:height,bytes:output)
    }
    public static func prepare(_ image: RGBImage, maxSoftTokens: Int = 280) throws -> PreparedImage {
        let size = try targetSize(width:image.width,height:image.height,maxSoftTokens:maxSoftTokens)
        let resized = try resize(image,width:size.width,height:size.height)
        let pw = size.width/16, ph = size.height/16
        var pixels = [Float](repeating:0,count:maxSoftTokens*9*768)
        var positions = [Int32](repeating:-1,count:maxSoftTokens*9*2)
        for py in 0..<ph { for px in 0..<pw {
            let patch = py*pw+px
            positions[patch*2] = Int32(px); positions[patch*2+1] = Int32(py)
            for y in 0..<16 { for x in 0..<16 { for c in 0..<3 {
                pixels[patch*768+(y*16+x)*3+c] = Float(Double(resized.bytes[((py*16+y)*size.width+px*16+x)*3+c])/255)
            }}}
        }}
        return PreparedImage(pixels:pixels,positions:positions,resizedRGB:resized.bytes,width:size.width,height:size.height,maxSoftTokens:maxSoftTokens)
    }
}
