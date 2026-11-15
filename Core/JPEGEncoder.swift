import Foundation
import CoreImage
import CoreVideo
import ImageIO

/// Encodage JPEG (V1 / MJPEG) : réduction en 720p + compression via Core Image (GPU).
/// L'image source n'est jamais conservée : seule la Data JPEG résultante sort d'ici.
final class JPEGEncoder {
    private let quality: Double
    private let shortSide: Int
    private let context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    init(quality: Double = 0.5, shortSide: Int = 720) {
        self.quality = quality
        self.shortSide = shortSide
    }

    func encode(_ pixelBuffer: CVPixelBuffer) -> Data? {
        autoreleasepool {
            let srcW = CVPixelBufferGetWidth(pixelBuffer)
            let srcH = CVPixelBufferGetHeight(pixelBuffer)
            let (w, h) = H264Encoder.targetSize(width: srcW, height: srcH, shortSide: shortSide)
            var image = CIImage(cvPixelBuffer: pixelBuffer)
            if w != srcW || h != srcH {
                image = image.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / CGFloat(srcW),
                                                                y: CGFloat(h) / CGFloat(srcH)))
                image = image.cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
            }
            let key = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
            return context.jpegRepresentation(of: image, colorSpace: colorSpace, options: [key: quality])
        }
    }
}
