import Foundation
import CoreGraphics
import CoreImage

/// Cheap "watch the desk" motion detector. Downsamples each frame to a
/// tiny grayscale buffer and compares mean-pixel-difference to a threshold.
/// Tunable via `threshold` (0.0…1.0, default ~3%).
///
/// Thread-safe: state is guarded by an internal lock. Call `evaluate(_:)`
/// from any background queue.
final class MotionDetector {

    /// Returned per evaluation.
    struct Reading: Equatable {
        let motion: Bool
        let delta: Double         // 0.0…1.0 mean absolute difference
        let timestamp: Date
    }

    var threshold: Double = 0.03
    var downsampleEdge: Int = 64    // 64x64 luminance buffer

    private let lock = NSLock()
    private var previous: [UInt8]?
    private let ciContext = CIContext()

    func reset() {
        lock.lock(); defer { lock.unlock() }
        previous = nil
    }

    /// Returns a `Reading`. First call after `reset()` always reports no
    /// motion (we need two frames to diff).
    func evaluate(_ image: CGImage) -> Reading {
        let size = CGSize(width: downsampleEdge, height: downsampleEdge)
        guard let buffer = grayBuffer(from: image, size: size) else {
            return Reading(motion: false, delta: 0, timestamp: Date())
        }
        lock.lock()
        defer { lock.unlock() }
        guard let prev = previous, prev.count == buffer.count else {
            previous = buffer
            return Reading(motion: false, delta: 0, timestamp: Date())
        }
        var total = 0
        for i in 0..<buffer.count {
            total += abs(Int(buffer[i]) - Int(prev[i]))
        }
        let delta = Double(total) / (Double(buffer.count) * 255.0)
        previous = buffer
        return Reading(motion: delta > threshold, delta: delta, timestamp: Date())
    }

    private func grayBuffer(from image: CGImage, size: CGSize) -> [UInt8]? {
        let width = Int(size.width)
        let height = Int(size.height)
        let bytesPerRow = width
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let cs = CGColorSpace(name: CGColorSpace.linearGray),
              let ctx = CGContext(data: &pixels,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        return pixels
    }
}
