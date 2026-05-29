import Foundation

/// Daemon-side mirror of the app's `GatewayAuthFileLock`. See the app copy in
/// `Mac/JarvisMac/MacBrain/GatewayAuthFileLock.swift` for the rationale (#33 —
/// dual-writer race on `gateway_paired_devices.json`). This target cannot import
/// the app target, so the logic is duplicated; keep the merge rules in sync.
enum GatewayAuthFileLock {

    /// Runs `body` while holding an exclusive advisory lock (`flock(LOCK_EX)`) on
    /// a sibling `.lock` file. Always released.
    static func withExclusiveLock(at url: URL, _ body: () -> Void) {
        let lockURL = url.deletingPathExtension().appendingPathExtension("lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { body(); return }
        defer { close(fd) }
        if flock(fd, LOCK_EX) != 0 { body(); return }
        defer { flock(fd, LOCK_UN) }
        body()
    }

    /// Reads and decodes the device list from disk, or `[]` on missing/corrupt.
    static func readDevices(at url: URL) -> [PairedDevice] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([PairedDevice].self, from: data) else {
            return []
        }
        return decoded
    }

    /// Encodes and atomically writes the device list.
    static func writeDevices(_ devices: [PairedDevice], to url: URL) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Merge keyed by device id. Revocation is sticky (wins); newest lastSeenAt
    /// is kept; other fields prefer the local copy; the `platform` field prefers
    /// whichever copy has a non-empty value. Devices present only on disk are
    /// retained (favour retention over deletion — see app copy for rationale).
    static func merge(local: [PairedDevice], disk: [PairedDevice]) -> [PairedDevice] {
        var byId: [String: PairedDevice] = [:]
        for d in disk { byId[d.id] = d }
        for l in local {
            if let existing = byId[l.id] {
                var m = l
                m.isRevoked = l.isRevoked || existing.isRevoked
                m.lastSeenAt = max(l.lastSeenAt, existing.lastSeenAt)
                if m.platform.isEmpty { m.platform = existing.platform }
                byId[l.id] = m
            } else {
                byId[l.id] = l
            }
        }
        return Array(byId.values)
    }
}
