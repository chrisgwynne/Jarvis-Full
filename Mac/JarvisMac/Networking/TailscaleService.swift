import Foundation
import Darwin   // getifaddrs
import Network

// MARK: - TailscaleStatus

struct TailscaleStatus: Equatable {
    var ip: String?          // e.g. "100.91.42.7"
    var hostname: String?    // MagicDNS name if resolvable, e.g. "my-mac.tail12345.ts.net"

    var isConnected: Bool { ip != nil }

    /// WebSocket URL suitable for the Android app to connect to.
    func wsURL(port: UInt16) -> String? {
        guard let ip else { return nil }
        return "ws://\(ip):\(port)"
    }

    /// JSON string to embed in a QR code for one-tap Android pairing.
    func qrPayload(port: UInt16, authToken: String?) -> String {
        let host = hostname ?? ip ?? "not-connected"
        var dict: [String: Any] = [
            "jarvis": true,          // identifier the Android app validates
            "host": host,
            "port": port,
        ]
        if let auth = authToken, !auth.isEmpty {
            dict["auth"] = auth
        }
        // Produce stable key order: jarvis, host, port, auth
        let ordered: [(String, Any)] = [
            ("jarvis", dict["jarvis"]!),
            ("host",   dict["host"]!),
            ("port",   dict["port"]!),
        ] + (dict["auth"] != nil ? [("auth", dict["auth"]!)] : [])

        let jsonObj = Dictionary(uniqueKeysWithValues: ordered)
        if let data = try? JSONSerialization.data(withJSONObject: jsonObj,
                                                   options: .sortedKeys),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }
}

// MARK: - TailscaleService

/// Polls network interfaces for the Tailscale IP (100.64.0.0/10 CGNAT range).
///
/// All blocking syscalls (`getifaddrs`, DNS) run on a detached background task —
/// the main actor is never touched until the result is ready.
@MainActor
final class TailscaleService {

    private(set) var status = TailscaleStatus()
    private var pollTask: Task<Void, Never>?
    /// Called on the main actor whenever the status changes.
    var onStatusChanged: ((TailscaleStatus) -> Void)?

    // MARK: - Lifecycle

    func start() {
        // First scan on background — never block main thread at startup.
        Task.detached(priority: .utility) { [weak self] in
            let s = await TailscaleService.scan()
            await MainActor.run {
                self?.status = s
                self?.onStatusChanged?(s)
            }
        }

        pollTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)  // 30s
                guard !Task.isCancelled else { return }
                let s = await TailscaleService.scan()
                await MainActor.run {
                    self?.status = s
                    self?.onStatusChanged?(s)
                }
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Trigger an immediate background rescan. Returns the new status once done.
    @discardableResult
    func refresh() -> TailscaleStatus {
        // Fire-and-forget on background; onStatusChanged called when done.
        Task.detached(priority: .utility) { [weak self] in
            let s = await TailscaleService.scan()
            await MainActor.run {
                self?.status = s
                self?.onStatusChanged?(s)
            }
        }
        return status   // returns cached value immediately — never blocks
    }

    // MARK: - Background scan (nonisolated — runs on cooperative thread pool)

    /// Full interface scan. Runs entirely on a background thread — safe to await
    /// from any context. Never blocks the main actor.
    nonisolated static func scan() async -> TailscaleStatus {
        // getifaddrs is fast (~microseconds) but still off-main for safety.
        let ip = findTailscaleIP()
        guard let ip else { return TailscaleStatus() }
        return TailscaleStatus(ip: ip, hostname: nil)
        // Note: hostname/reverse-DNS lookup deliberately omitted.
        // getnameinfo(NI_NAMEREQD) can block for the system DNS timeout (5-10s)
        // when no PTR record exists — which crashes/stalls the whole UI.
        // The IP address is sufficient for the QR code and connection info.
    }

    /// Enumerate network interfaces and return the first address in the
    /// Tailscale CGNAT range (100.64.0.0/10 = 100.64.0.0 – 100.127.255.255).
    nonisolated static func findTailscaleIP() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(first) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            let addr = current.pointee
            guard addr.ifa_addr != nil,
                  addr.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            // NI_NUMERICHOST — returns the IP as a string, no DNS, never blocks.
            let rc = getnameinfo(addr.ifa_addr,
                                 socklen_t(MemoryLayout<sockaddr_in>.size),
                                 &buf, socklen_t(buf.count),
                                 nil, 0, NI_NUMERICHOST)
            guard rc == 0 else { continue }
            let ip = String(cString: buf)
            if isTailscaleAddress(ip) { return ip }
        }
        return nil
    }

    /// True for addresses in 100.64.0.0/10 (Tailscale's reserved CGNAT range).
    nonisolated static func isTailscaleAddress(_ ip: String) -> Bool {
        let octets = ip.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets[0] == 100 else { return false }
        return octets[1] >= 64 && octets[1] <= 127
    }

    /// Return the best local LAN IP (first RFC-1918 address that isn't Tailscale).
    /// Returns nil if only loopback/link-local are found.
    nonisolated static func findLocalIP() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(first) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            let addr = current.pointee
            guard addr.ifa_addr != nil,
                  addr.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(addr.ifa_addr, socklen_t(MemoryLayout<sockaddr_in>.size),
                                 &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
            guard rc == 0 else { continue }
            let ip = String(cString: buf)

            // Skip loopback (127.x) and Tailscale (100.64–127.x)
            guard !ip.hasPrefix("127.") && !isTailscaleAddress(ip) else { continue }

            // Accept RFC-1918 ranges: 10.x, 172.16-31.x, 192.168.x
            let octets = ip.split(separator: ".").compactMap { Int($0) }
            guard octets.count == 4 else { continue }
            if octets[0] == 10 { return ip }
            if octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31 { return ip }
            if octets[0] == 192 && octets[1] == 168 { return ip }
        }
        return nil
    }
}

