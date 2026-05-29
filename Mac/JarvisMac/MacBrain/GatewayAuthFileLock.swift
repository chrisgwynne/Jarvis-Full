import Foundation

/// Cross-process file-locking + merge helper for `gateway_paired_devices.json`.
///
/// The paired-device registry is written by BOTH the Mac app (`GatewayAuthStore`)
/// and the JarvisBrainDaemon (`DaemonAuthStore`). Without coordination a write
/// from one process can clobber an unflushed change from the other (#33 — a
/// device revocation could be silently lost under a daemon heartbeat write).
///
/// This helper provides:
///   • `withExclusiveLock` — POSIX advisory `flock(LOCK_EX)` around a critical
///     section so the two processes serialise their read-modify-write cycles.
///   • `merge` — combines the in-memory list with the on-disk list so neither
///     writer loses the other's changes. Revocation is *sticky* (wins), and the
///     newest `lastSeenAt` is kept per device.
///
/// The daemon target carries its own mirror of this logic (it cannot import the
/// app target); keep the two merge rules in sync if either is changed.
enum GatewayAuthFileLock {

    /// Runs `body` while holding an exclusive advisory lock on `url`. The lock is
    /// taken on a sibling `.lock` file so it never interferes with atomic renames
    /// of the data file itself. Always released, even on throw.
    static func withExclusiveLock(at url: URL, _ body: () -> Void) {
        let lockURL = url.deletingPathExtension().appendingPathExtension("lock")
        // Ensure the lock file exists.
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            // Could not open the lock file — fall back to running without the
            // lock rather than dropping the write entirely.
            body()
            return
        }
        defer { close(fd) }
        // Block until we hold the exclusive lock.
        if flock(fd, LOCK_EX) != 0 {
            body()
            return
        }
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

    /// Merges the local (in-memory) list with the on-disk list, keyed by device
    /// id. Rules:
    ///   • A device present in either source is kept.
    ///   • Revocation is sticky — if EITHER copy is revoked, the merged device is
    ///     revoked (we never silently un-revoke a device due to a stale write).
    ///   • `lastSeenAt` takes the maximum of the two copies.
    ///   • Other fields prefer the local copy (the writer initiating the save).
    ///
    /// This intentionally favours retention over deletion: a device present only
    /// on disk is kept. The tradeoff is that a hard `removeDevice` may re-appear
    /// (still revoked, since revocation is sticky) if the other process has not
    /// yet dropped it — which is the safe failure mode versus losing a
    /// revocation. A revoked device cannot authenticate regardless.
    static func merge(local: [PairedDevice], disk: [PairedDevice]) -> [PairedDevice] {
        var byId: [String: PairedDevice] = [:]
        for d in disk { byId[d.id] = d }
        for l in local {
            if let existing = byId[l.id] {
                var m = l
                m.isRevoked = l.isRevoked || existing.isRevoked
                m.lastSeenAt = max(l.lastSeenAt, existing.lastSeenAt)
                byId[l.id] = m
            } else {
                byId[l.id] = l
            }
        }
        return Array(byId.values)
    }
}
