import XCTest
@testable import JarvisMac

/// Tests for the Mac Camera HTTP server layer.
/// These are unit tests on MacCameraFrameStore, MacCameraDiagnostics,
/// and MacCameraHttpRoutes — no real NWConnection or AVCaptureSession needed.
@MainActor
final class MacCameraServerTests: XCTestCase {

    // MARK: - MacCameraFrameStore

    func testFrameStoreStartsEmpty() {
        let store = MacCameraFrameStore()
        XCTAssertNil(store.latestJPEG)
        XCTAssertNil(store.lastFrameTime)
    }

    func testFrameStoreKeepsOnlyLatestFrame() {
        let store = MacCameraFrameStore()
        let first  = Data([0x01, 0x02])
        let second = Data([0x03, 0x04])
        store.update(jpeg: first)
        store.update(jpeg: second)
        XCTAssertEqual(store.latestJPEG, second, "Store must retain only the latest frame")
    }

    func testFrameStoreClearResetsState() {
        let store = MacCameraFrameStore()
        store.update(jpeg: Data([0xFF]))
        store.clear()
        XCTAssertNil(store.latestJPEG)
        XCTAssertNil(store.lastFrameTime)
    }

    func testFrameStoreTimestampUpdatedOnWrite() {
        let store = MacCameraFrameStore()
        let before = Date()
        store.update(jpeg: Data([0xAA]))
        let after = Date()
        XCTAssertNotNil(store.lastFrameTime)
        XCTAssertGreaterThanOrEqual(store.lastFrameTime!, before)
        XCTAssertLessThanOrEqual(store.lastFrameTime!, after)
    }

    // MARK: - MacCameraDiagnostics

    func testDiagnosticsInitialState() {
        let diag = MacCameraDiagnostics()
        XCTAssertFalse(diag.isEnabled)
        XCTAssertEqual(diag.permission, "notDetermined")
        XCTAssertFalse(diag.isCapturing)
        XCTAssertEqual(diag.activeViewers, 0)
        XCTAssertNil(diag.lastFrameTime)
    }

    func testDiagnosticsServerEnabledDisabled() {
        let diag = MacCameraDiagnostics()
        diag.log(.serverEnabled)
        XCTAssertTrue(diag.isEnabled)
        diag.log(.serverDisabled)
        XCTAssertFalse(diag.isEnabled)
        XCTAssertFalse(diag.isCapturing)
        XCTAssertEqual(diag.activeViewers, 0)
    }

    func testDiagnosticsClientCountIncrementDecrement() {
        let diag = MacCameraDiagnostics()
        diag.log(.clientConnected)
        diag.log(.clientConnected)
        XCTAssertEqual(diag.activeViewers, 2)
        diag.log(.clientDisconnected)
        XCTAssertEqual(diag.activeViewers, 1)
    }

    func testDiagnosticsActiveViewersFloorAtZero() {
        let diag = MacCameraDiagnostics()
        diag.log(.clientDisconnected)  // disconnecting from zero is safe
        XCTAssertEqual(diag.activeViewers, 0)
    }

    func testDiagnosticsPermissionDeniedSetsString() {
        let diag = MacCameraDiagnostics()
        diag.log(.permissionDenied)
        XCTAssertEqual(diag.permission, "denied")
    }

    func testDiagnosticsFrameEncodedUpdatesTimestamp() {
        let diag = MacCameraDiagnostics()
        XCTAssertNil(diag.lastFrameTime)
        diag.log(.frameEncoded)
        XCTAssertNotNil(diag.lastFrameTime)
        XCTAssertEqual(diag.totalFrames, 1)
    }

    // MARK: - MacCameraHttpRoutes — health does NOT start camera

    func testHealthDoesNotStartCamera() async {
        let routes     = MacCameraHttpRoutes()
        let service    = MacCameraService()
        let frameStore = MacCameraFrameStore()
        routes.cameraService = service
        routes.frameStore    = frameStore

        let (status, _, ct) = routes.handleHealth()
        XCTAssertEqual(status, 200)
        XCTAssertEqual(ct, "application/json")
        XCTAssertFalse(service.isRunning, "Health endpoint must not start AVCaptureSession")
    }

    func testHealthResponseContainsRequiredFields() async throws {
        let routes = MacCameraHttpRoutes()
        let (_, body, _) = routes.handleHealth()
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertNotNil(json["ok"])
        XCTAssertNotNil(json["cameraAvailable"])
        XCTAssertNotNil(json["cameraPermission"])
        XCTAssertNotNil(json["streaming"])
        XCTAssertNotNil(json["activeClients"])
        XCTAssertNotNil(json["timestamp"])
    }

    // MARK: - MacCameraHttpRoutes — snapshot timeout

    func testSnapshotTimeoutReturns503WhenNoCamera() async {
        let routes     = MacCameraHttpRoutes()
        let service    = MacCameraService()   // permission = .notDetermined → can't start
        let frameStore = MacCameraFrameStore()
        routes.cameraService = service
        routes.frameStore    = frameStore

        // Snapshot with 0 ms of real wait since permission is denied — will time out.
        // We shorten the window by testing on a service that never produces frames.
        let start = Date()
        let (status, _, ct) = await routes.handleSnapshot()
        let elapsed = Date().timeIntervalSince(start)

        // 503 because no frame arrived
        XCTAssertEqual(status, 503)
        XCTAssertEqual(ct, "application/json")
        // Should have waited ~2 s before giving up
        XCTAssertGreaterThan(elapsed, 1.5)
    }

    // MARK: - MacCameraHttpRoutes — active client count

    func testActiveClientCountStartsAtZero() {
        let routes = MacCameraHttpRoutes()
        XCTAssertEqual(routes.activeClientCount, 0)
    }

    // MARK: - pbxproj UUID regression

}
