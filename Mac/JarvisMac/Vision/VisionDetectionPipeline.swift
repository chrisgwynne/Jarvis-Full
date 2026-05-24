import Foundation
import Vision
import CoreML
import AVFoundation
import CoreImage

// MARK: - VisionDetectionPipeline

/// Off-main-thread actor that runs Vision requests on pixel buffers.
/// Processes every Nth frame (default 4) to stay near 7fps from a 30fps feed.
actor VisionDetectionPipeline {

    // MARK: Private state

    private var frameCounter: Int = 0
    private let processEveryNthFrame: Int
    private var onDetection: ((DetectionFrame) -> Void)?
    private var coreMLModel: VNCoreMLModel?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Previous frame stored as a CIImage for motion delta computation.
    private var previousFrameImage: CIImage?

    // MARK: Init

    init(processEveryNthFrame: Int = 4) {
        self.processEveryNthFrame = max(1, processEveryNthFrame)
    }

    // MARK: Public API

    func setDetectionCallback(_ cb: @escaping (DetectionFrame) -> Void) {
        onDetection = cb
    }

    /// Optionally load a CoreML object-detection model (e.g. YOLOv8).
    /// Throws if the model URL is invalid or the model cannot be compiled.
    func loadCoreMLModel(at url: URL) throws {
        let compiledURL = try MLModel.compileModel(at: url)
        let mlModel = try MLModel(contentsOf: compiledURL)
        coreMLModel = try VNCoreMLModel(for: mlModel)
    }

    /// Main entry point. Called from a camera delegate or display-link callback.
    /// Skips frames that don't hit the Nth-frame cadence.
    func process(pixelBuffer: CVPixelBuffer, cameraFeedID: UUID, timestamp: TimeInterval) async {
        frameCounter += 1
        guard frameCounter % processEveryNthFrame == 0 else { return }

        let motionIntensity = computeMotionIntensity(pixelBuffer: pixelBuffer)
        let detections = runVisionRequests(on: pixelBuffer, cameraFeedID: cameraFeedID, timestamp: timestamp)

        let frame = DetectionFrame(
            timestamp: timestamp,
            cameraFeedID: cameraFeedID,
            rawDetections: detections,
            motionIntensity: motionIntensity
        )

        // Store frame for next motion delta computation
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        previousFrameImage = ciImage

        onDetection?(frame)
    }

    // MARK: Vision pipeline

    private func runVisionRequests(
        on pixelBuffer: CVPixelBuffer,
        cameraFeedID: UUID,
        timestamp: TimeInterval
    ) -> [RawDetection] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        var detections: [RawDetection] = []

        detections += runHumanDetection(handler: handler, cameraFeedID: cameraFeedID, timestamp: timestamp)
        detections += runFaceDetection(handler: handler, cameraFeedID: cameraFeedID, timestamp: timestamp)
        detections += runObjectDetection(handler: handler, cameraFeedID: cameraFeedID, timestamp: timestamp)

        return detections
    }

    private func runHumanDetection(
        handler: VNImageRequestHandler,
        cameraFeedID: UUID,
        timestamp: TimeInterval
    ) -> [RawDetection] {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false

        do {
            try handler.perform([request])
        } catch {
            return []
        }

        guard let results = request.results else { return [] }

        return results.map { observation in
            let box = observation.boundingBox  // Vision: bottom-left origin, normalized
            let flipped = CGRect(
                x: box.minX,
                y: 1.0 - box.maxY,
                width: box.width,
                height: box.height
            )
            return RawDetection(
                cls: .person,
                bounds: flipped,
                confidence: Float(observation.confidence),
                frameTimestamp: timestamp,
                cameraFeedID: cameraFeedID
            )
        }
    }

    private func runFaceDetection(
        handler: VNImageRequestHandler,
        cameraFeedID: UUID,
        timestamp: TimeInterval
    ) -> [RawDetection] {
        let request = VNDetectFaceRectanglesRequest()

        do {
            try handler.perform([request])
        } catch {
            return []
        }

        guard let results = request.results else { return [] }

        return results.map { observation in
            let box = observation.boundingBox
            let flipped = CGRect(
                x: box.minX,
                y: 1.0 - box.maxY,
                width: box.width,
                height: box.height
            )
            return RawDetection(
                cls: .face,
                bounds: flipped,
                confidence: Float(observation.confidence),
                frameTimestamp: timestamp,
                cameraFeedID: cameraFeedID
            )
        }
    }

    /// Runs CoreML object detection if a model is loaded, otherwise returns empty.
    private func runObjectDetection(
        handler: VNImageRequestHandler,
        cameraFeedID: UUID,
        timestamp: TimeInterval
    ) -> [RawDetection] {
        guard let model = coreMLModel else { return [] }

        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFit

        do {
            try handler.perform([request])
        } catch {
            return []
        }

        guard let results = request.results else { return [] }

        var detections: [RawDetection] = []

        for observation in results {
            if let recognized = observation as? VNRecognizedObjectObservation {
                guard let topLabel = recognized.labels.first else { continue }
                let cls = detectionClass(from: topLabel.identifier)
                let box = recognized.boundingBox
                let flipped = CGRect(
                    x: box.minX,
                    y: 1.0 - box.maxY,
                    width: box.width,
                    height: box.height
                )
                let detection = RawDetection(
                    cls: cls,
                    bounds: flipped,
                    confidence: Float(recognized.confidence),
                    frameTimestamp: timestamp,
                    cameraFeedID: cameraFeedID
                )
                detections.append(detection)
            }
        }

        return detections
    }

    // MARK: Motion intensity

    /// Computes a 0.0–1.0 scalar representing pixel-level motion relative to the previous frame.
    /// Returns 0.0 when no previous frame is available.
    private func computeMotionIntensity(pixelBuffer: CVPixelBuffer) -> Float {
        let currentImage = CIImage(cvPixelBuffer: pixelBuffer)

        guard let previous = previousFrameImage else {
            return 0.0
        }

        // Resize both images to a small thumbnail to keep the diff cheap.
        let thumbSize = CGSize(width: 64, height: 64)
        let scaleFilter = CIFilter(name: "CILanczosScaleTransform")!

        let currentW = currentImage.extent.width
        let scale = thumbSize.width / currentW

        scaleFilter.setValue(currentImage, forKey: kCIInputImageKey)
        scaleFilter.setValue(scale, forKey: kCIInputScaleKey)
        scaleFilter.setValue(1.0, forKey: kCIInputAspectRatioKey)
        guard let scaledCurrent = scaleFilter.outputImage else { return 0.0 }

        scaleFilter.setValue(previous, forKey: kCIInputImageKey)
        scaleFilter.setValue(scale, forKey: kCIInputScaleKey)
        guard let scaledPrev = scaleFilter.outputImage else { return 0.0 }

        // Compute absolute difference
        guard let diffFilter = CIFilter(name: "CIAbsoluteDifference") else { return 0.0 }
        diffFilter.setValue(scaledCurrent, forKey: kCIInputImageKey)
        diffFilter.setValue(scaledPrev, forKey: kCIInputBackgroundImageKey)
        guard let diffImage = diffFilter.outputImage else { return 0.0 }

        // Convert to grayscale and average
        guard let grayFilter = CIFilter(name: "CIColorControls") else { return 0.0 }
        grayFilter.setValue(diffImage, forKey: kCIInputImageKey)
        grayFilter.setValue(0.0, forKey: kCIInputSaturationKey)
        guard let grayImage = grayFilter.outputImage else { return 0.0 }

        // Render to a 1x1 pixel to get mean luminance via area average
        guard let avgFilter = CIFilter(name: "CIAreaAverage",
                                       parameters: [kCIInputImageKey: grayImage,
                                                    kCIInputExtentKey: CIVector(cgRect: grayImage.extent)])
        else { return 0.0 }
        guard let avgImage = avgFilter.outputImage else { return 0.0 }

        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            avgImage,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        // pixel[0] = R channel of the grayscale average (R == G == B for gray)
        let intensity = Float(pixel[0]) / 255.0
        return min(intensity * 4.0, 1.0)  // amplify: typical motion sits around 0.1–0.3 raw
    }

    // MARK: Helpers

    /// Maps a CoreML label string to a DetectionClass.
    private func detectionClass(from identifier: String) -> DetectionClass {
        let lower = identifier.lowercased()
        if lower.contains("person") || lower.contains("human") || lower.contains("pedestrian") {
            return .person
        } else if lower.contains("face") {
            return .face
        } else if lower.contains("car") || lower.contains("truck") || lower.contains("bus")
                    || lower.contains("vehicle") || lower.contains("motorcycle") || lower.contains("bicycle") {
            return .vehicle
        } else if lower.contains("phone") || lower.contains("cell") || lower.contains("mobile") {
            return .phone
        } else if lower.contains("laptop") || lower.contains("notebook") {
            return .laptop
        } else if lower.contains("backpack") || lower.contains("bag") || lower.contains("suitcase") {
            return .backpack
        } else if lower.contains("camera") || lower.contains("cctv") || lower.contains("surveillance") {
            return .surveillanceCamera
        } else if lower.contains("dog") || lower.contains("canine") {
            return .dog
        } else if lower.contains("cat") || lower.contains("feline") {
            return .cat
        } else if lower.contains("monitor") || lower.contains("screen") || lower.contains("tv") {
            return .monitor
        } else {
            return .unknown
        }
    }
}
