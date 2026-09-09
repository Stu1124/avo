// deps: Avo/Agent/ImageInput.swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main
struct ImageInputTests {
    static func main() throws {
        let path = "/tmp/avo-image-input-test.png"
        let context = CGContext(data: nil, width: 3200, height: 1600, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 800, y: 400, width: 800, height: 400))
        let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        let encoded = ImageInput.encode(path: path)!
        precondition(encoded.url.hasPrefix("data:image/jpeg;base64,"))
        let data = Data(base64Encoded: String(encoded.url.split(separator: ",", maxSplits: 1)[1]))!
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
        precondition(props[kCGImagePropertyPixelWidth] as? Int == 2048 && props[kCGImagePropertyPixelHeight] as? Int == 1024)
        precondition(ImageInput.encode(path: "/nonexistent/avo.png") == nil)
        print("PASS: attachment normalization, image size budget, MIME correctness, missing image failure")
    }
}
