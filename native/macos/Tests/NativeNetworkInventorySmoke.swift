import Darwin
import Foundation

private enum InventorySmokeError: Error { case failed }
@main
struct NativeNetworkInventorySmoke {
    static func main() throws {
        guard let line = readLine(), let expected = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String] else { throw InventorySmokeError.failed }
        let flags = UInt32(IFF_UP | IFF_RUNNING | IFF_BROADCAST)
        for (bytes, mask) in [([5, 2, 0, 0, 255], UInt32(0xff000000)), ([6, 2, 0, 0, 255, 255], UInt32(0xffff0000)),
                             ([7, 2, 0, 0, 255, 255, 255], UInt32(0xffffff00)), ([8, 2, 0, 0, 255, 255, 255, 128], UInt32(0xffffff80))] {
            try check(NativeNetworkInventory.ipv4Mask(bytes: bytes.map(UInt8.init)) == mask)
        }
        for bytes: [UInt8] in [[], [1], [2, 0], [3, 2], [17, 2], [7, 2, 0, 0, 255, 255]] {
            try check(NativeNetworkInventory.ipv4Mask(bytes: bytes) == nil)
        }
        func entry(_ name: String, _ address: UInt32 = 0xc0000202, _ mask: UInt32 = 0xffffff00, _ state: UInt32? = nil) -> NativeIPv4InterfaceRecord {
            NativeIPv4InterfaceRecord(name: name, flags: state ?? flags, address: address, mask: mask)
        }
        try check(try NativeNetworkInventory.names(records: [entry("en0"), entry("en1", 0xc0000282, 0xffffff80)]) == ["en0", "en1"])
        try check(try NativeNetworkInventory.names(records: [entry("en0", 0xc00002ff, 0xfffffe00)]) == ["en0"])
        for invalid in [entry("en0", 0xc0000200), entry("en0", 0xc00002ff), entry("en0", 0xc0000202, 0xffff00ff),
            entry("en0", 0xc0000202, 0xfe000000), entry("en0", 0xc0000202, 0xfffffffe), entry("en0", 0x00000202), entry("en0", 0xe0000202),
            entry("en0", 0xc0000202, 0xffffff00, flags & ~UInt32(IFF_UP)), entry("en0", 0xc0000202, 0xffffff00, flags & ~UInt32(IFF_RUNNING)),
            entry("en0", 0xc0000202, 0xffffff00, flags & ~UInt32(IFF_BROADCAST)), entry("en-0")] {
            try check(try NativeNetworkInventory.names(records: [invalid]).isEmpty)
        }
        try check(try NativeNetworkInventory.names(records: [entry("en0"), entry("en0", 0xc0000203)]).isEmpty)
        try check(try NativeNetworkInventory.names(records: [entry("en0"), entry("en0")]).isEmpty)
        try capacity { _ = try NativeNetworkInventory.names(records: (0..<65).map { entry("en\($0)") }) }
        try capacity { _ = try NativeNetworkInventory.names(records: Array(repeating: entry("en0"), count: 4097)) }
        // Reads only OS inventory; no socket is created and no addresses are logged.
        let actual = try NativeNetworkInventory.names()
        try check(actual.count <= 64 && actual == actual.sorted() && actual.allSatisfy(NativeNetworkRecord.validName))
        try check(actual == expected)
        print("native network independent scope and actual passive inventory checks passed")
    }
    private static func capacity(_ action: () throws -> Void) throws {
        do { try action(); throw InventorySmokeError.failed } catch NativeNetworkPreferenceError.capacity {}
    }
    private static func check(_ value: Bool) throws { if !value { throw InventorySmokeError.failed } }
}
