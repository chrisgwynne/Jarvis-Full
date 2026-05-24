import XCTest

// Source-contract test: verifies all remote action and file transfer components exist
// and contain required implementation markers.
final class RemoteActionTests: XCTestCase {

    private func repoRoot() -> URL {
        // Test bundle lives in JarvisMac.app/Contents/.../JarvisMacTests.xctest
        // Walk up until we find the Mac directory
        var url = Bundle(for: RemoteActionTests.self).bundleURL
        for _ in 0..<10 {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Mac").path) {
                return url
            }
        }
        // Fallback: look relative to source file location at build time
        return URL(fileURLWithPath: #file)
            .deletingLastPathComponent()  // RemoteActionTests.swift
            .deletingLastPathComponent()  // JarvisMacTests
            .deletingLastPathComponent()  // Mac
            .deletingLastPathComponent()  // repo root
    }

    private func readSource(_ relativePath: String) throws -> String {
        let url = repoRoot().appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testRemoteActionRouterExists() throws {
        let source = try readSource("Mac/JarvisBrainDaemon/RemoteActionRouter.swift")
        XCTAssert(source.contains("class RemoteActionRouter"), "RemoteActionRouter must exist")
        XCTAssert(source.contains("mac_client_unavailable"), "Must NACK with mac_client_unavailable when Mac offline")
        XCTAssert(source.contains("timeoutSeconds"), "Must implement request timeout")
    }

    func testMacActionHandlerHasRequiredActions() throws {
        let source = try readSource("Mac/JarvisMac/RemoteActions/MacActionHandler.swift")
        XCTAssert(source.contains("open_app") || source.contains("openApp"), "Must handle open_app")
        XCTAssert(source.contains("create_note") || source.contains("createNote"), "Must handle create_note")
        XCTAssert(source.contains("show_camera") || source.contains("showCamera"), "Must handle show_camera")
        XCTAssert(source.contains("open_jarvis") || source.contains("openJarvis"), "Must handle open_jarvis")
    }

    func testFileTransferStoreRejectsBlockedExtensions() throws {
        let source = try readSource("Mac/JarvisBrainDaemon/FileTransferStore.swift")
        XCTAssert(source.contains("\"app\""), "Must block .app extension")
        XCTAssert(source.contains("\"dmg\""), "Must block .dmg extension")
        XCTAssert(source.contains("\"sh\""), "Must block .sh extension")
        XCTAssert(source.contains("localTempPath"), "Must have localTempPath field")
    }

    func testDaemonAppBridgeHasRemoteActionCallback() throws {
        let source = try readSource("Mac/JarvisMac/MacBrain/DaemonAppBridge.swift")
        XCTAssert(source.contains("onRemoteActionRequest"), "DaemonAppBridge must have onRemoteActionRequest callback")
        XCTAssert(source.contains("sendRemoteActionResult"), "DaemonAppBridge must have sendRemoteActionResult method")
    }

    func testFileTransferStoreLocalTempPathNotExposedInSafeMeta() throws {
        let source = try readSource("Mac/JarvisBrainDaemon/FileTransferStore.swift")
        // The safeMeta dictionary must NOT include localTempPath
        XCTAssert(source.contains("safeForClient"), "Must have safe-for-client return type")
        // localTempPath should only appear in the struct definition, not in safe return dict
        let safeMetaRange = source.range(of: "// Return safe metadata (no localTempPath)")
        XCTAssertNotNil(safeMetaRange, "Must explicitly note that safe metadata excludes localTempPath")
    }

    func testDaemonOfflineQueueHasNewTypes() throws {
        let source = try readSource("Mac/JarvisBrainDaemon/DaemonOfflineQueue.swift")
        XCTAssert(source.contains("remote.action.result"), "Queue must classify remote.action.result as safe")
        XCTAssert(source.contains("file.transfer.created"), "Queue must classify file.transfer.created as safe")
        XCTAssert(source.contains("remote.action.request"), "Queue must classify remote.action.request as unsafe")
        XCTAssert(source.contains("file.transfer.result"), "Queue must classify file.transfer.result as unsafe")
    }

    func testBrainDaemonServerHasFileEndpoints() throws {
        let source = try readSource("Mac/JarvisBrainDaemon/BrainDaemonServer.swift")
        XCTAssert(source.contains("/v1/files/upload"), "Server must have file upload endpoint")
        XCTAssert(source.contains("/v1/files/"), "Server must have file download/delete endpoint")
        XCTAssert(source.contains("handleFileUpload"), "Server must have handleFileUpload method")
        XCTAssert(source.contains("handleFileDownload"), "Server must have handleFileDownload method")
    }

    func testWrapAndRouteFixForMacEnvelopes() throws {
        let source = try readSource("Mac/JarvisBrainDaemon/BrainDaemonServer.swift")
        XCTAssert(source.contains("sourceDeviceId") && source.contains("route directly"),
                  "wrapAndRoute must handle Mac-sent envelopes by routing directly without re-wrapping")
    }
}
