import CryptoKit
import Foundation
import OSLog

private let transferLogger = Logger(subsystem: "com.jarvis.brain", category: "filetransfer")

// MARK: - Transfer metadata

struct FileTransferMeta: Codable {
    let transferId: String
    let sourceDeviceId: String
    let filename: String
    let mimeType: String
    let sizeBytes: Int
    let sha256: String
    let createdAt: Date
    let expiresAt: Date
    let targetPlatform: String      // "mac"
    let openOnMac: Bool
    let suggestedAction: String     // "view" | "save" | "import"
    let userVisibleName: String
    let localTempPath: String       // NEVER logged, never returned to clients
}

// MARK: - FileTransferStore

/// Manages temporary file storage for Android → Mac file transfers.
/// Files are stored in a temp directory and expired after 1 hour.
///
/// SECURITY:
/// - localTempPath is NEVER sent to clients or logged.
/// - sha256 is verified after upload and before download.
/// - Dangerous extensions are rejected at upload time.
/// - Auth required for all endpoints (enforced in BrainDaemonServer).
final class FileTransferStore {
    static let shared = FileTransferStore()

    private let lock = NSLock()
    private var transfers: [String: FileTransferMeta] = [:]

    private let maxFileSizeBytes: Int
    private let expiryInterval: TimeInterval = 3600  // 1 hour
    private let tempDir: URL

    // SECURITY: reject these extensions regardless of MIME type
    static let blockedExtensions: Set<String> = [
        "app", "dmg", "exe", "sh", "command", "pkg", "bat", "vbs", "ps1",
        "jar", "dex", "ipa", "msi", "run", "bin"
    ]

    // Allowed MIME type prefixes
    static let allowedMimePrefixes: [String] = [
        "image/", "video/", "audio/",
        "text/", "application/pdf",
        "application/json", "application/zip",
        "application/msword",
        "application/vnd.openxmlformats",
        "application/vnd.ms-",
    ]

    private(set) var uploadCount: Int = 0
    private(set) var downloadCount: Int = 0
    private(set) var rejectedCount: Int = 0
    private(set) var expiredCount: Int = 0

    init() {
        // Default 100 MB; override with JARVIS_MAX_FILE_MB env var
        let envMb = ProcessInfo.processInfo.environment["JARVIS_MAX_FILE_MB"].flatMap { Int($0) } ?? 100
        maxFileSizeBytes = envMb * 1024 * 1024

        let tmp = FileManager.default.temporaryDirectory
        tempDir = tmp.appendingPathComponent("JarvisTransfers", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    // MARK: - Store upload

    /// Stores an uploaded file. Returns the transfer metadata (without localTempPath).
    /// Returns nil on rejection (blocked extension, MIME type, or size).
    func storeUpload(
        filename: String,
        mimeType: String,
        data: Data,
        sourceDeviceId: String,
        targetPlatform: String,
        openOnMac: Bool,
        suggestedAction: String,
        userVisibleName: String
    ) -> (meta: FileTransferMeta, safeForClient: [String: Any])? {
        // Size check
        guard data.count <= maxFileSizeBytes else {
            rejectedCount += 1
            transferLogger.warning("transfer: rejected oversized file size=\(data.count) filename=\(filename, privacy: .public)")
            return nil
        }

        // Extension check
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        guard !Self.blockedExtensions.contains(ext) else {
            rejectedCount += 1
            transferLogger.warning("transfer: rejected blocked extension=\(ext, privacy: .public) filename=\(filename, privacy: .public)")
            return nil
        }

        // MIME type check
        let mimeOk = Self.allowedMimePrefixes.contains { mimeType.hasPrefix($0) }
        guard mimeOk else {
            rejectedCount += 1
            transferLogger.warning("transfer: rejected disallowed mimeType=\(mimeType, privacy: .public)")
            return nil
        }

        let transferId = UUID().uuidString
        let sha256 = computeSHA256(data)
        let safeFilename = sanitiseFilename(filename)
        let destPath = tempDir.appendingPathComponent("\(transferId)_\(safeFilename)")

        do {
            try data.write(to: destPath, options: .atomic)
        } catch {
            transferLogger.error("transfer: failed to write temp file: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let now = Date()
        let meta = FileTransferMeta(
            transferId: transferId,
            sourceDeviceId: sourceDeviceId,
            filename: safeFilename,
            mimeType: mimeType,
            sizeBytes: data.count,
            sha256: sha256,
            createdAt: now,
            expiresAt: now.addingTimeInterval(expiryInterval),
            targetPlatform: targetPlatform,
            openOnMac: openOnMac,
            suggestedAction: suggestedAction,
            userVisibleName: userVisibleName.isEmpty ? safeFilename : userVisibleName,
            localTempPath: destPath.path  // NEVER returned to clients
        )

        lock.withLock {
            evictExpired()
            transfers[transferId] = meta
        }

        uploadCount += 1
        transferLogger.info("transfer: stored transferId=\(transferId) filename=\(safeFilename, privacy: .public) size=\(data.count) sha256=\(sha256.prefix(8), privacy: .public)...")

        // Return safe metadata (no localTempPath)
        let safe: [String: Any] = [
            "transferId": transferId,
            "filename": safeFilename,
            "mimeType": mimeType,
            "sizeBytes": data.count,
            "sha256": sha256,
            "expiresAt": ISO8601DateFormatter().string(from: meta.expiresAt),
            "targetPlatform": targetPlatform,
            "openOnMac": openOnMac,
            "suggestedAction": suggestedAction,
            "userVisibleName": meta.userVisibleName
        ]
        return (meta, safe)
    }

    // MARK: - Retrieve for download

    /// Returns (data, meta) for a transfer. Returns nil if not found, expired, or sha256 mismatch.
    /// Only allows download if the requesting platform matches targetPlatform.
    func retrieve(transferId: String, requestingPlatform: String) -> (data: Data, meta: FileTransferMeta)? {
        let meta: FileTransferMeta? = lock.withLock {
            evictExpired()
            return transfers[transferId]
        }
        guard let m = meta else {
            transferLogger.debug("transfer: retrieve — transferId=\(transferId) not found (expired or never existed)")
            return nil
        }

        // Only Mac can download (targetPlatform = "mac")
        guard requestingPlatform == m.targetPlatform else {
            transferLogger.warning("transfer: retrieve — platform mismatch requestingPlatform=\(requestingPlatform, privacy: .public) targetPlatform=\(m.targetPlatform, privacy: .public)")
            return nil
        }

        let path = URL(fileURLWithPath: m.localTempPath)
        guard let data = try? Data(contentsOf: path) else {
            transferLogger.warning("transfer: retrieve — file not found on disk for transferId=\(transferId)")
            return nil
        }

        // Verify sha256
        let actualSha256 = computeSHA256(data)
        guard actualSha256 == m.sha256 else {
            transferLogger.error("transfer: sha256 mismatch for transferId=\(transferId) — file corrupted")
            return nil
        }

        downloadCount += 1
        transferLogger.info("transfer: delivered transferId=\(transferId) size=\(data.count) to platform=\(requestingPlatform, privacy: .public)")
        return (data, m)
    }

    // MARK: - Delete

    func delete(transferId: String) {
        let meta: FileTransferMeta? = lock.withLock { transfers.removeValue(forKey: transferId) }
        if let m = meta {
            try? FileManager.default.removeItem(atPath: m.localTempPath)
            transferLogger.debug("transfer: deleted transferId=\(transferId)")
        }
    }

    // MARK: - Meta (safe, no path)

    func safeMeta(for transferId: String) -> [String: Any]? {
        let m: FileTransferMeta? = lock.withLock { transfers[transferId] }
        guard let m else { return nil }
        return [
            "transferId": m.transferId,
            "filename": m.filename,
            "mimeType": m.mimeType,
            "sizeBytes": m.sizeBytes,
            "sha256": m.sha256,
            "expiresAt": ISO8601DateFormatter().string(from: m.expiresAt),
            "targetPlatform": m.targetPlatform,
            "openOnMac": m.openOnMac,
            "suggestedAction": m.suggestedAction,
            "userVisibleName": m.userVisibleName
        ]
    }

    // MARK: - Expire

    private func evictExpired() {
        let now = Date()
        let before = transfers.count
        for (id, m) in transfers where m.expiresAt < now {
            try? FileManager.default.removeItem(atPath: m.localTempPath)
            transfers.removeValue(forKey: id)
        }
        let evicted = before - transfers.count
        if evicted > 0 {
            expiredCount += evicted
            transferLogger.debug("transfer: evicted \(evicted) expired transfers")
        }
    }

    // MARK: - Crypto helpers

    private func computeSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func sanitiseFilename(_ name: String) -> String {
        let safe = name.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._- ")).inverted).joined()
        return String(safe.prefix(128)).trimmingCharacters(in: .whitespaces)
    }
}
