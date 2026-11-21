import Darwin
import Foundation

/// Chooses the sync protocol listen port (DESIGN §3, WP-D finding).
///
/// Upstream's default `tcp://:22000` / `quic://:22000` uses SO_REUSEPORT, so an
/// embedded engine silently *shares* 22000 with another Syncthing on the same
/// host (the official app on a Mac running us as Designed for iPad, or the
/// host's instance seen from the Simulator), and incoming connections land on
/// either process. When 22000 is taken — or always under `isiOSAppOnMac` — we
/// move to a free port in 22001…22099 (falling back to a random port) and
/// persist it in config.xml (`listenAddresses`) and `psy-app-state.json`.
///
/// Only `default` and explicit `:22000` entries are rewritten; any other
/// user-configured address is left alone.
public enum ListenAddressPlanner {
    public static let defaultPort = 22000
    public static let alternatePorts = 22001...22099
    /// Upstream's expansion of `default` (lib/config): TCP, QUIC, relays.
    static let defaultRelay = "dynamic+https://relays.syncthing.net/endpoint"

    /// True if nothing else on this host is bound to `port` (TCP and UDP,
    /// IPv4 and IPv6). Binds *without* SO_REUSEPORT, so a socket held by
    /// another Syncthing (which sets SO_REUSEPORT) makes this fail.
    public static func isPortFree(_ port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }
        for family in [AF_INET, AF_INET6] {
            for type in [SOCK_STREAM, SOCK_DGRAM] where !canBind(family: family, type: type, port: port) {
                return false
            }
        }
        return true
    }

    /// Port to use instead of 22000, or nil if 22000 is fine.
    /// `stored` is a previously chosen port (kept for stable addresses).
    public static func alternatePort(stored: Int?, defaultFree: Bool, preferAlternate: Bool,
                                     isFree: (Int) -> Bool) -> Int? {
        if let stored { return stored }
        guard preferAlternate || !defaultFree else { return nil }
        return alternatePorts.first(where: isFree) ?? 0
    }

    /// Rewrites `listenAddresses` to use `port`. Returns nil when nothing
    /// changes (already moved, or the user configured custom addresses).
    public static func rewrite(_ addresses: [String], port: Int) -> [String]? {
        var out: [String] = []
        for address in addresses {
            if address == "default" {
                out += ["tcp://:\(port)", "quic://:\(port)", defaultRelay]
            } else if let rewritten = replacingDefaultPort(address, with: port) {
                out.append(rewritten)
            } else {
                out.append(address)
            }
        }
        var seen = Set<String>()
        out = out.filter { seen.insert($0).inserted }
        return out == addresses ? nil : out
    }

    /// `tcp://:22000`, `quic://0.0.0.0:22000`, `tcp://[::]:22000` → same with `port`.
    static func replacingDefaultPort(_ address: String, with port: Int) -> String? {
        guard let scheme = address.range(of: "://"),
              ["tcp", "tcp4", "tcp6", "quic", "quic4", "quic6"].contains(String(address[..<scheme.lowerBound])),
              address.hasSuffix(":\(defaultPort)") else { return nil }
        return String(address.dropLast(String(defaultPort).count)) + String(port)
    }

    private static func canBind(family: Int32, type: Int32, port: Int) -> Bool {
        let fd = socket(family, type, 0)
        guard fd >= 0 else { return true }   // family unavailable: not a conflict
        defer { close(fd) }
        if family == AF_INET6 {
            var on: Int32 = 1
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
        }
        let result: Int32
        if family == AF_INET {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr = in_addr(s_addr: INADDR_ANY)
            result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        } else {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = in_port_t(UInt16(port).bigEndian)
            addr.sin6_addr = in6addr_any
            result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        }
        return result == 0 || errno != EADDRINUSE
    }
}
