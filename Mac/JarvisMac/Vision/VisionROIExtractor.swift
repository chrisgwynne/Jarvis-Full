import Foundation
import Vision
import CoreGraphics
import ImageIO

// MARK: - ROIResult

/// Output of a local Apple Vision preprocessing pass.
/// Contains optional crops that the cloud provider can then analyse at
/// higher effective resolution than the full downscaled frame would allow.
struct ROIResult {
    /// Face crop padded by `facePaddingFactor` — useful for glasses/hat/hair.
    let faceCrop:   CGImage?
    /// Hand-region crop — useful for held-object identification.
    let handCrop:   CGImage?
    /// Normalised bounding boxes of detected faces (in image coords, 0-1 origin top-left).
    let faceRects:  [CGRect]
    /// Normalised bounding boxes of detected hands.
    let handRects:  [CGRect]
    /// Whether any face was detected with confidence > threshold.
    let hasFace:    Bool
    /// Whether any hand was detected with confidence > threshold.
    let hasHand:    Bool
}

// MARK: - VisionROIExtractor

/// Uses Apple's on-device Vision framework to detect faces and hands, then
/// crops those regions from the source frame at high quality.
///
/// Runs synchronously on whatever queue the caller supplies — always call
/// from a background thread to avoid blocking the main actor.
///
/// **Why local preprocessing?**
/// A 1024-px full frame might show the face at only 180 px wide. Sending a
/// 512-px face crop separately gives the cloud model ×8 more pixels to work
/// with for glasses, beard, skin tone — dramatically improving accuracy.
enum VisionROIExtractor {

    // MARK: Configuration

    /// Fraction of face bounding-box width added as padding on each side.
    static let facePaddingFactor: CGFloat = 0.55

    /// Fraction of hand bounding-box width added as padding on each side.
    static let handPaddingFactor: CGFloat = 0.50

    /// Minimum Vision observation confidence to count as a detection.
    static let minConfidence: Float = 0.30

    // MARK: Public API

    /// Run face + hand detection on `image` and return cropped regions.
    /// Returns quickly even on failure — all errors produce nil crops.
    static func extract(from image: CGImage) -> ROIResult {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        var faceObs:  [VNFaceObservation]      = []
        var handObs:  [VNHumanHandPoseObservation] = []

        // ── Face rectangles ────────────────────────────────────────────────
        let faceReq = VNDetectFaceRectanglesRequest()
        // ── Hand pose (for bounding box approximation) ────────────────────
        let handReq = VNDetectHumanHandPoseRequest()
        handReq.maximumHandCount = 2

        do {
            try handler.perform([faceReq, handReq])
            faceObs = (faceReq.results ?? []).filter { $0.confidence >= minConfidence }
            handObs = (handReq.results ?? []).filter { $0.confidence >= minConfidence }
        } catch {
            // Non-fatal — just return empty result
        }

        // ── Vision → CGImage coordinate transform ─────────────────────────
        // Vision uses normalised coordinates with (0,0) at bottom-left.
        // CGImage has (0,0) at top-left. Flip Y.
        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)

        func visionToImage(_ rect: CGRect) -> CGRect {
            CGRect(
                x:      rect.minX  * imgW,
                y:      (1.0 - rect.maxY) * imgH,   // Y flip
                width:  rect.width  * imgW,
                height: rect.height * imgH
            )
        }

        // ── Face crop ──────────────────────────────────────────────────────
        let faceCrop: CGImage?
        let faceRects: [CGRect]

        if let bestFace = faceObs.max(by: { $0.boundingBox.width < $1.boundingBox.width }) {
            let rawRect = visionToImage(bestFace.boundingBox)
            let padded  = rawRect.padded(by: facePaddingFactor, in: CGSize(width: imgW, height: imgH))
            faceRects   = [bestFace.boundingBox]
            faceCrop    = image.cropping(to: padded)
        } else {
            faceRects = []
            faceCrop  = nil
        }

        // ── Hand region crop ───────────────────────────────────────────────
        // VNHumanHandPoseObservation doesn't expose a bounding box directly.
        // Compute it from the wrist and fingertip landmarks.
        let handCrop: CGImage?
        let handRects: [CGRect]

        if let bestHand = handObs.first {
            if let handBox = approximateHandBoundingBox(from: bestHand,
                                                         imgW: imgW, imgH: imgH) {
                let padded = handBox.padded(by: handPaddingFactor, in: CGSize(width: imgW, height: imgH))
                handRects  = [handBox]
                handCrop   = image.cropping(to: padded)
            } else {
                handRects = []
                handCrop  = nil
            }
        } else {
            handRects = []
            handCrop  = nil
        }

        return ROIResult(
            faceCrop:  faceCrop,
            handCrop:  handCrop,
            faceRects: faceRects,
            handRects: handRects,
            hasFace:   faceCrop != nil,
            hasHand:   handCrop != nil
        )
    }

    // MARK: - Helpers

    /// Approximate a bounding box from the hand pose landmarks (wrist + all finger tips).
    private static func approximateHandBoundingBox(
        from obs: VNHumanHandPoseObservation,
        imgW: CGFloat,
        imgH: CGFloat
    ) -> CGRect? {
        guard let points = try? obs.recognizedPoints(.all) else { return nil }
        let pts = points.values.filter { $0.confidence > 0.2 }
        guard pts.count >= 3 else { return nil }

        // Vision coords: (0,0) bottom-left, Y up → flip for image coords
        let xs = pts.map { $0.location.x * imgW }
        let ys = pts.map { (1.0 - $0.location.y) * imgH }

        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return nil }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

// MARK: - CGRect padding helper

private extension CGRect {
    /// Expands the rect by `factor` × its own dimensions, clamped to `bounds`.
    func padded(by factor: CGFloat, in bounds: CGSize) -> CGRect {
        let dx = width  * factor
        let dy = height * factor
        return CGRect(
            x:      max(0,             minX - dx),
            y:      max(0,             minY - dy),
            width:  min(bounds.width,  maxX + dx) - max(0, minX - dx),
            height: min(bounds.height, maxY + dy) - max(0, minY - dy)
        )
    }
}
