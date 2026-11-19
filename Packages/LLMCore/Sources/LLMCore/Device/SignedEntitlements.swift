import Foundation

/// Reads the entitlements the running app was actually signed with, and what its embedded
/// provisioning profile grants. iOS has no public API that says whether an entitlement such as
/// `com.apple.developer.kernel.increased-memory-limit` is in effect; the next best evidence is
/// (1) the key is in the executable's code signature, (2) the provisioning profile grants it,
/// and (3) the measured process limit (see ``MemorySnapshot/processLimitBytes``).
public struct EntitlementReport: Hashable, Sendable, Codable {
    public static let increasedMemoryLimitKey = "com.apple.developer.kernel.increased-memory-limit"

    /// The executable has a code signature with an entitlements blob.
    public var signatureHasEntitlements: Bool
    /// Value of the increased-memory-limit key in the code signature (`nil` = absent).
    public var increasedMemoryLimitSigned: Bool?
    /// Value of the key in `embedded.mobileprovision` (`nil` = absent or no profile).
    public var increasedMemoryLimitInProfile: Bool?
    /// All entitlement keys found in the code signature (sorted).
    public var signedKeys: [String]

    /// Signed and granted by the profile (the kernel then applies the higher limit).
    public var increasedMemoryLimitLikelyEffective: Bool {
        increasedMemoryLimitSigned == true && increasedMemoryLimitInProfile != false
    }

    /// Report for the running process.
    public static func current() -> EntitlementReport {
        let signed = Bundle.main.executableURL.flatMap {
            CodeSignatureInspector.entitlements(ofExecutableAt: $0)
        }
        let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
            .flatMap { CodeSignatureInspector.provisioningProfileEntitlements(at: $0) }
        return EntitlementReport(
            signatureHasEntitlements: signed != nil,
            increasedMemoryLimitSigned: signed?[increasedMemoryLimitKey] as? Bool,
            increasedMemoryLimitInProfile: profile?[increasedMemoryLimitKey] as? Bool,
            signedKeys: signed.map { $0.keys.sorted() } ?? [])
    }
}

/// Minimal Mach-O code-signature reader (thin or fat binaries).
public enum CodeSignatureInspector {
    private static let mhMagic64: UInt32 = 0xFEED_FACF
    private static let fatMagic: UInt32 = 0xCAFE_BABE
    private static let fatMagic64: UInt32 = 0xCAFE_BABF
    private static let lcCodeSignature: UInt32 = 0x1D
    private static let cpuTypeARM64: UInt32 = 0x0100_000C
    private static let superBlobMagic: UInt32 = 0xFADE_0CC0
    private static let entitlementsBlobMagic: UInt32 = 0xFADE_7171
    private static let entitlementsSlot: UInt32 = 5

    /// The XML entitlements dictionary embedded in the code signature of the Mach-O at `url`.
    public static func entitlements(ofExecutableAt url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return entitlements(inMachO: data)
    }

    /// Same as ``entitlements(ofExecutableAt:)`` for in-memory data (tests).
    public static func entitlements(inMachO data: Data) -> [String: Any]? {
        guard let plist = entitlementsPlistData(inMachO: data) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: plist, format: nil))
            as? [String: Any]
    }

    /// The `Entitlements` dictionary of a provisioning profile (a CMS-signed XML plist).
    public static func provisioningProfileEntitlements(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
            let start = data.range(of: Data("<?xml".utf8)),
            let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return nil }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        let plist =
            (try? PropertyListSerialization.propertyList(from: plistData, format: nil))
            as? [String: Any]
        return plist?["Entitlements"] as? [String: Any]
    }

    static func entitlementsPlistData(inMachO data: Data) -> Data? {
        guard data.count >= 8 else { return nil }
        let magicBE = data.uint32BE(at: 0)
        if magicBE == fatMagic || magicBE == fatMagic64 {
            let is64 = magicBE == fatMagic64
            let count = Int(data.uint32BE(at: 4))
            let entrySize = is64 ? 32 : 20
            for index in 0..<count {
                let entry = 8 + index * entrySize
                guard entry + entrySize <= data.count else { return nil }
                let cpuType = data.uint32BE(at: entry)
                let offset =
                    is64 ? Int(data.uint64BE(at: entry + 8)) : Int(data.uint32BE(at: entry + 8))
                if cpuType == cpuTypeARM64 {
                    return entitlementsPlistData(inThinMachO: data, sliceOffset: offset)
                }
            }
            return nil
        }
        return entitlementsPlistData(inThinMachO: data, sliceOffset: 0)
    }

    private static func entitlementsPlistData(inThinMachO data: Data, sliceOffset: Int) -> Data? {
        guard sliceOffset + 32 <= data.count, data.uint32LE(at: sliceOffset) == mhMagic64 else {
            return nil
        }
        let commandCount = Int(data.uint32LE(at: sliceOffset + 16))
        var cursor = sliceOffset + 32
        for _ in 0..<commandCount {
            guard cursor + 8 <= data.count else { return nil }
            let command = data.uint32LE(at: cursor)
            let size = Int(data.uint32LE(at: cursor + 4))
            guard size >= 8 else { return nil }
            if command == lcCodeSignature, cursor + 16 <= data.count {
                let dataOffset = Int(data.uint32LE(at: cursor + 8))
                return entitlementsPlistData(inSuperBlobAt: sliceOffset + dataOffset, of: data)
            }
            cursor += size
        }
        return nil
    }

    private static func entitlementsPlistData(inSuperBlobAt start: Int, of data: Data) -> Data? {
        guard start + 12 <= data.count, data.uint32BE(at: start) == superBlobMagic else {
            return nil
        }
        let count = Int(data.uint32BE(at: start + 8))
        for index in 0..<count {
            let entry = start + 12 + index * 8
            guard entry + 8 <= data.count else { return nil }
            guard data.uint32BE(at: entry) == entitlementsSlot else { continue }
            let blob = start + Int(data.uint32BE(at: entry + 4))
            guard blob + 8 <= data.count, data.uint32BE(at: blob) == entitlementsBlobMagic else {
                return nil
            }
            let length = Int(data.uint32BE(at: blob + 4))
            guard length >= 8, blob + length <= data.count else { return nil }
            return data.subdata(in: (data.startIndex + blob + 8)..<(data.startIndex + blob + length))
        }
        return nil
    }
}

extension Data {
    fileprivate func uint32BE(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 { value = value << 8 | UInt32(self[startIndex + offset + index]) }
        return value
    }

    fileprivate func uint64BE(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 { value = value << 8 | UInt64(self[startIndex + offset + index]) }
        return value
    }

    fileprivate func uint32LE(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in (0..<4).reversed() {
            value = value << 8 | UInt32(self[startIndex + offset + index])
        }
        return value
    }
}
