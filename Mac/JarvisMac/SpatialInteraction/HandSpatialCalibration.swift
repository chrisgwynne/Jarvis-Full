import Foundation
import CoreGraphics

// MARK: - CalibrationSample

/// A single confirmed calibration pair: where Vision saw the hand vs. where
/// the target dot actually was on screen.
struct CalibrationSample: Codable {
    /// Raw Vision-framework indexTip in normalised image space.
    /// Origin: bottom-left. X: 0 (left) → 1 (right). Y: 0 (bottom) → 1 (top).
    let visionPoint: CGPoint

    /// Known target position in view coordinates.
    /// Origin: top-left. Y increases downward.
    let targetPoint: CGPoint
}

// MARK: - AffineCalibration

/// 6-parameter 2D affine transform mapping raw Vision-space to view-space.
///
/// Encodes any combination of: scale, shear, rotation, translation,
/// horizontal mirror, vertical flip.  Replaces the hardcoded linear remap
/// in `SpatialCursorEngine` when a calibration has been performed.
///
///   x' = a·vx + b·vy + tx
///   y' = c·vx + d·vy + ty
struct AffineCalibration: Codable {
    var a, b, tx: CGFloat   // X output row
    var c, d, ty: CGFloat   // Y output row

    var sampleCount:  Int
    var averageError: CGFloat   // residual RMS (pts)
    var maxError:     CGFloat   // worst-case residual (pts)
    var calibratedAt: Date

    /// Quality 0–1 (1 = excellent ≤ 10 pt average error).
    var qualityScore: Double {
        guard sampleCount >= 3 else { return 0 }
        return max(0.0, 1.0 - Double(averageError) / 40.0)
    }

    func apply(_ visionPt: CGPoint) -> CGPoint {
        CGPoint(
            x: a * visionPt.x + b * visionPt.y + tx,
            y: c * visionPt.x + d * visionPt.y + ty
        )
    }
}

// MARK: - CalibrationQualityLevel

enum CalibrationQualityLevel {
    case excellent    // < 10 pts avg
    case good         // < 20 pts avg
    case fair         // < 40 pts avg
    case poor         // ≥ 40 pts avg
    case insufficient // < 3 samples

    init(averageError: CGFloat, sampleCount: Int) {
        if sampleCount < 3        { self = .insufficient }
        else if averageError < 10 { self = .excellent    }
        else if averageError < 20 { self = .good         }
        else if averageError < 40 { self = .fair         }
        else                      { self = .poor         }
    }

    var label: String {
        switch self {
        case .excellent:    return "Excellent"
        case .good:         return "Good"
        case .fair:         return "Fair"
        case .poor:         return "Poor — redo recommended"
        case .insufficient: return "Insufficient data"
        }
    }

    var redoRecommended: Bool { self == .poor || self == .insufficient }
}

// MARK: - HandCalibrationEngine

/// Pure static functions — no state.
enum HandCalibrationEngine {

    /// Minimum confirmed samples before a transform can be fitted.
    static let minimumSamples = 3

    /// Ordered target positions for a calibration session in view-space.
    ///
    /// The first 5 (indices 0–4) are required; 5–8 are optional bonus points.
    static func targetPositions(in size: CGSize) -> [CGPoint] {
        let mx = size.width  * 0.12
        let my = size.height * 0.14
        let cx = size.width  * 0.50
        let cy = size.height * 0.50
        let r  = size.width  - mx
        let b  = size.height - my
        return [
            CGPoint(x: cx, y: cy),   // 0 — centre (required)
            CGPoint(x: mx, y: my),   // 1 — top-left (required)
            CGPoint(x: r,  y: my),   // 2 — top-right (required)
            CGPoint(x: mx, y: b),    // 3 — bottom-left (required)
            CGPoint(x: r,  y: b),    // 4 — bottom-right (required)
            CGPoint(x: mx, y: cy),   // 5 — mid-left
            CGPoint(x: r,  y: cy),   // 6 — mid-right
            CGPoint(x: cx, y: my),   // 7 — top-centre
            CGPoint(x: cx, y: b),    // 8 — bottom-centre
        ]
    }

    /// Fit an affine transform from the supplied calibration samples using
    /// least-squares normal equations.  Returns nil when the system is
    /// degenerate (collinear inputs) or when fewer than `minimumSamples`
    /// are provided.
    static func fit(samples: [CalibrationSample]) -> AffineCalibration? {
        guard samples.count >= minimumSamples else { return nil }

        // Build AtA (3×3) and Atb vectors for X and Y outputs separately.
        // Each sample contributes row [vx, vy, 1] to matrix A.
        var AtA  = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
        var Atbx = [Double](repeating: 0, count: 3)
        var Atby = [Double](repeating: 0, count: 3)

        for s in samples {
            let row: [Double] = [Double(s.visionPoint.x),
                                  Double(s.visionPoint.y),
                                  1.0]
            let bx = Double(s.targetPoint.x)
            let by = Double(s.targetPoint.y)
            for i in 0..<3 {
                for j in 0..<3 { AtA[i][j] += row[i] * row[j] }
                Atbx[i] += row[i] * bx
                Atby[i] += row[i] * by
            }
        }

        guard let xp = solve3x3(AtA, Atbx),
              let yp = solve3x3(AtA, Atby) else { return nil }

        var calib = AffineCalibration(
            a: CGFloat(xp[0]), b: CGFloat(xp[1]), tx: CGFloat(xp[2]),
            c: CGFloat(yp[0]), d: CGFloat(yp[1]), ty: CGFloat(yp[2]),
            sampleCount:  samples.count,
            averageError: 0,
            maxError:     0,
            calibratedAt: .now
        )

        // Residual calculation
        var sumErr: CGFloat = 0
        var maxErr: CGFloat = 0
        for s in samples {
            let pred = calib.apply(s.visionPoint)
            let err  = hypot(pred.x - s.targetPoint.x,
                             pred.y - s.targetPoint.y)
            sumErr += err
            maxErr  = max(maxErr, err)
        }
        calib.averageError = sumErr / CGFloat(samples.count)
        calib.maxError     = maxErr
        return calib
    }

    // MARK: - Private — Gaussian elimination (3×3)

    /// Solve Ax = b for a 3×3 system via Gaussian elimination with partial pivoting.
    private static func solve3x3(_ A: [[Double]], _ b: [Double]) -> [Double]? {
        // Augmented matrix [A | b]
        var aug = (0..<3).map { i in A[i] + [b[i]] }

        for col in 0..<3 {
            // Partial pivot
            var maxRow = col
            for row in (col + 1)..<3 {
                if abs(aug[row][col]) > abs(aug[maxRow][col]) { maxRow = row }
            }
            aug.swapAt(col, maxRow)
            guard abs(aug[col][col]) > 1e-10 else { return nil }

            for row in (col + 1)..<3 {
                let f = aug[row][col] / aug[col][col]
                for k in col...3 { aug[row][k] -= f * aug[col][k] }
            }
        }

        // Back-substitution
        var x = [Double](repeating: 0, count: 3)
        for i in stride(from: 2, through: 0, by: -1) {
            x[i] = aug[i][3]
            for j in (i + 1)..<3 { x[i] -= aug[i][j] * x[j] }
            x[i] /= aug[i][i]
        }
        return x
    }
}

// MARK: - HandCalibrationStore

/// Persists the active spatial calibration to disk and vends it to the cursor engine.
@MainActor
final class HandCalibrationStore {
    static let shared = HandCalibrationStore()

    private(set) var calibration: AffineCalibration?

    private let fileURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        let dir = support.appendingPathComponent("JarvisMac", isDirectory: true)
        fileURL = dir.appendingPathComponent("hand_spatial_calibration.json")
        load()
    }

    func save(_ calib: AffineCalibration) {
        calibration = calib
        persist()
    }

    func reset() {
        calibration = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Persistence

    private func persist() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir,
                                                  withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(calibration) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let c    = try? JSONDecoder().decode(AffineCalibration.self,
                                                   from: data) else { return }
        calibration = c
    }
}
