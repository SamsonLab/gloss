import CoreGraphics
import Foundation
@preconcurrency import Vision

package enum OCRTextRecognizer {
    package static func recognize(_ image: CGImage) async throws -> String {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])
            try Task.checkCancellation()

            let regions = (request.results ?? []).compactMap { observation -> OCRTextRegion? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return OCRTextRegion(
                    text: candidate.string,
                    boundingBox: observation.boundingBox,
                    confidence: candidate.confidence
                )
            }
            return try OCRTextLayout.orderedText(from: regions)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
