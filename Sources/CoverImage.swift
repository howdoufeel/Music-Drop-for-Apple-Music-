import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Album art is square: video frames are cropped to their centre and large images scaled down.
enum CoverImage {
    static func squareJPEG(_ data: Data, maximumSide: Int = 1000) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let side = min(image.width, image.height)
        guard side >= 64, let square = image.cropping(to: CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2,
                                                                  width: side, height: side)) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        if side > maximumSide {
            // Re-read through the thumbnail path so scaling uses ImageIO's own resampling.
            guard let cropped = encode(square),
                  let scaledSource = CGImageSourceCreateWithData(cropped as CFData, nil),
                  let scaled = CGImageSourceCreateThumbnailAtIndex(scaledSource, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: maximumSide
                  ] as CFDictionary) else { return nil }
            CGImageDestinationAddImage(destination, scaled, options as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, square, options as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func encode(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
