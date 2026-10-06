//
//  NetworkInfo.swift
//  GameLibraryServer
//
//  The addresses the modal shows: the device's `.local` name when it has
//  one, and its LAN IPv4 addresses for networks where mDNS doesn't reach.
//

import Darwin
import Foundation

public enum NetworkInfo {
    /// `<name>.local`, or nil when the system only knows itself as localhost.
    public static func localHostName() -> String? {
        var name = ProcessInfo.processInfo.hostName
        if name.isEmpty || name.lowercased().hasPrefix("localhost") {
            var buf = [CChar](repeating: 0, count: 256)
            guard gethostname(&buf, buf.count) == 0 else { return nil }
            name = cString(buf)
        }
        let lower = name.lowercased()
        if lower.isEmpty || lower.hasPrefix("localhost") { return nil }
        if lower.hasSuffix(".local") { return name }
        // A DHCP-assigned search domain is not reachable by name from a browser.
        return name.contains(".") ? nil : name + ".local"
    }

    static func cString(_ buf: [CChar]) -> String {
        String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// LAN IPv4 addresses, Wi-Fi/Ethernet (`en*`) first; never loopback,
    /// link-local or cellular.
    public static func ipv4Addresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var found: [(String, String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            if name.hasPrefix("pdp_ip") { continue }   // cellular
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = cString(host)
            if ip.hasPrefix("169.254.") { continue }
            found.append((name, ip))
        }
        return found.sorted { a, b in
            let ae = a.0.hasPrefix("en"), be = b.0.hasPrefix("en")
            return ae != be ? ae : a.0 < b.0
        }.map(\.1)
    }
}
