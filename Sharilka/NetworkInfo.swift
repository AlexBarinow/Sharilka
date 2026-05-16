//
//  NetworkInfo.swift
//  Sharilka
//
//  Detects local IPv4 addresses on active network interfaces.
//

import Foundation

nonisolated(unsafe) private let _addressCache = AddressCache()

private final class AddressCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: [String] = []
    private var lastUpdate: Date = .distantPast

    func get(maxAge: TimeInterval = 5) -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        if Date().timeIntervalSince(lastUpdate) < maxAge {
            return cached
        }
        return nil
    }

    func set(_ addresses: [String]) {
        lock.lock()
        defer { lock.unlock() }
        cached = addresses
        lastUpdate = Date()
    }
}

enum NetworkInfo {
    /// Returns a list of local IPv4 addresses on likely LAN interfaces (en0, en1, etc.)
    static func localIPv4Addresses() -> [String] {
        if let cached = _addressCache.get() {
            return cached
        }

        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return []
        }
        defer { freeifaddrs(ifaddr) }

        var ptr = firstAddr
        while true {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family

            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                // Include common LAN interfaces
                if name.hasPrefix("en") || name.hasPrefix("bridge") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let result = getnameinfo(
                        interface.ifa_addr,
                        socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil, 0,
                        NI_NUMERICHOST
                    )
                    if result == 0 {
                        let addr = String(cString: hostname)
                        if !addr.hasPrefix("127.") {
                            addresses.append("\(addr) (\(name))")
                        }
                    }
                }
            }

            guard let next = interface.ifa_next else { break }
            ptr = next
        }

        _addressCache.set(addresses)
        return addresses
    }

    /// Returns the local hostname
    static func localHostName() -> String {
        ProcessInfo.processInfo.hostName
    }
}
