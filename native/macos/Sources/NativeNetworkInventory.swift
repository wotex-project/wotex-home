import Darwin
import Foundation

struct NativeIPv4InterfaceRecord: Sendable {
    let name: String
    let flags: UInt32
    let address: UInt32
    let mask: UInt32
}

enum NativeNetworkInventory {
    static func names() throws -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { throw NativeNetworkPreferenceError.unavailable }
        defer { if let first { freeifaddrs(first) } }
        var cursor = first; var count = 0; var records: [NativeIPv4InterfaceRecord] = []
        while let current = cursor {
            guard count < 4096 else { throw NativeNetworkPreferenceError.capacity }
            count += 1; cursor = current.pointee.ifa_next
            let item = current.pointee
            guard let address = item.ifa_addr, Int32(address.pointee.sa_family) == AF_INET,
                  address.pointee.sa_len >= MemoryLayout<sockaddr_in>.size,
                  let name = item.ifa_name, strnlen(name, 16) < 16,
                  let text = String(validatingCString: name) else { continue }
            let local = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
            var netmask: UInt32 = 0
            if let mask = item.ifa_netmask {
                let pointer = UnsafeRawPointer(mask)
                let length = Int(pointer.load(as: UInt8.self))
                if (2...MemoryLayout<sockaddr_in>.size).contains(length) {
                    // Darwin returns packed trailing-zero netmasks. Never load
                    // an entire sockaddr_in from its shorter OS allocation.
                    netmask = ipv4Mask(bytes: Array(UnsafeRawBufferPointer(start: pointer, count: length))) ?? 0
                }
            }
            records.append(NativeIPv4InterfaceRecord(name: text, flags: item.ifa_flags,
                address: UInt32(bigEndian: local), mask: netmask))
        }
        return try names(records: records)
    }

    static func ipv4Mask(bytes: [UInt8]) -> UInt32? {
        guard (2...MemoryLayout<sockaddr_in>.size).contains(bytes.count), Int(bytes[0]) == bytes.count,
              Int32(bytes[1]) == AF_INET, MemoryLayout<sockaddr_in>.offset(of: \.sin_addr) == 4 else { return nil }
        var result: UInt32 = 0
        if bytes.count > 4 {
            for index in 4..<min(8, bytes.count) { result |= UInt32(bytes[index]) << (8 * (7 - index)) }
        }
        return result
    }

    // Pure independent vectors cannot select or bind an OS interface.
    static func names(records: [NativeIPv4InterfaceRecord]) throws -> [String] {
        guard records.count <= 4096 else { throw NativeNetworkPreferenceError.capacity }
        let grouped = Dictionary(grouping: records, by: \.name)
        var offered: [String] = []
        let required = UInt32(IFF_UP | IFF_RUNNING | IFF_BROADCAST)
        for (name, addresses) in grouped {
            guard NativeNetworkRecord.validName(name), addresses.count == 1, let item = addresses.first,
                  item.flags & required == required else { continue }
            let prefix = item.mask.nonzeroBitCount
            guard (8...30).contains(prefix), item.mask == UInt32.max << (32 - prefix),
                  item.address >> 24 > 0, item.address >> 24 < 224 else { continue }
            let network = item.address & item.mask
            let broadcast = network | ~item.mask
            guard item.address != network, item.address != broadcast else { continue }
            offered.append(name)
            guard offered.count <= 64 else { throw NativeNetworkPreferenceError.capacity }
        }
        return offered.sorted()
    }
}
