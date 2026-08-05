import CoreGraphics
import CoreImage
import Foundation
import Vision

enum BackgroundRemovalError: LocalizedError {
    case noSubject
    case renderingFailed

    var errorDescription: String? {
        switch self {
        case .noSubject:
            return L("No foreground subject was found")
        case .renderingFailed:
            return L("Could not remove the background")
        }
    }
}

/// Apple's on-device subject-lifting pipeline, exposed as a small synchronous
/// engine so callers can run it off the main actor. The input has already had
/// EXIF orientation baked in by `Cropper.previewFrame`.
enum BackgroundRemover {
    static func removeBackground(from image: CGImage) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try handler.perform([request])

        guard let observation = request.results?.first,
              !observation.allInstances.isEmpty
        else { throw BackgroundRemovalError.noSubject }

        let pixelBuffer = try observation.generateMaskedImage(
            ofInstances: observation.allInstances,
            from: handler,
            croppedToInstancesExtent: false
        )
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let result = CIContext(options: [.cacheIntermediates: false])
            .createCGImage(ciImage, from: ciImage.extent)
        else { throw BackgroundRemovalError.renderingFailed }
        return result
    }
}
