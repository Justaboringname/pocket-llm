import Foundation
import Testing

@testable import LLMCore

@Suite("Code-signature entitlements")
struct EntitlementsTests {

    /// Builds a minimal thin arm64 Mach-O whose LC_CODE_SIGNATURE points at a SuperBlob that
    /// contains an XML entitlements blob.
    private func syntheticMachO(entitlements: [String: Any]) throws -> Data {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: entitlements, format: .xml, options: 0)

        func le32(_ value: UInt32) -> [UInt8] {
            withUnsafeBytes(of: value.littleEndian, Array.init)
        }
        func be32(_ value: UInt32) -> [UInt8] {
            withUnsafeBytes(of: value.bigEndian, Array.init)
        }

        let headerSize = 32
        let commandSize = 16
        let signatureOffset = headerSize + commandSize
        // SuperBlob: magic, length, count, one index entry (type 5 → offset 20)
        let entitlementsBlob = be32(0xFADE_7171) + be32(UInt32(8 + plist.count)) + Array(plist)
        let superBlob =
            be32(0xFADE_0CC0) + be32(UInt32(20 + entitlementsBlob.count)) + be32(1) + be32(5)
            + be32(20) + entitlementsBlob

        var bytes: [UInt8] = []
        bytes += le32(0xFEED_FACF)  // MH_MAGIC_64
        bytes += le32(0x0100_000C)  // CPU_TYPE_ARM64
        bytes += le32(0)  // subtype
        bytes += le32(2)  // MH_EXECUTE
        bytes += le32(1)  // ncmds
        bytes += le32(UInt32(commandSize))  // sizeofcmds
        bytes += le32(0)  // flags
        bytes += le32(0)  // reserved
        bytes += le32(0x1D)  // LC_CODE_SIGNATURE
        bytes += le32(UInt32(commandSize))
        bytes += le32(UInt32(signatureOffset))
        bytes += le32(UInt32(superBlob.count))
        bytes += superBlob
        return Data(bytes)
    }

    @Test func readsEntitlementsFromThinBinary() throws {
        let data = try syntheticMachO(entitlements: [
            EntitlementReport.increasedMemoryLimitKey: true,
            "application-identifier": "TEAM.example",
        ])
        let entitlements = try #require(CodeSignatureInspector.entitlements(inMachO: data))
        #expect(entitlements[EntitlementReport.increasedMemoryLimitKey] as? Bool == true)
        #expect(entitlements["application-identifier"] as? String == "TEAM.example")
    }

    @Test func readsEntitlementsFromFatBinary() throws {
        let thin = try syntheticMachO(entitlements: ["k": true])
        func be32(_ value: UInt32) -> [UInt8] {
            withUnsafeBytes(of: value.bigEndian, Array.init)
        }
        let sliceOffset: UInt32 = 4096
        var fat: [UInt8] = be32(0xCAFE_BABE) + be32(1)
        fat += be32(0x0100_000C) + be32(0) + be32(sliceOffset) + be32(UInt32(thin.count)) + be32(12)
        fat += [UInt8](repeating: 0, count: Int(sliceOffset) - fat.count)
        let data = Data(fat) + thin
        let entitlements = try #require(CodeSignatureInspector.entitlements(inMachO: data))
        #expect(entitlements["k"] as? Bool == true)
    }

    @Test func garbageReturnsNil() {
        #expect(CodeSignatureInspector.entitlements(inMachO: Data([1, 2, 3])) == nil)
        #expect(CodeSignatureInspector.entitlements(inMachO: Data(count: 64)) == nil)
    }

    @Test func provisioningProfileParsing() throws {
        let profile: [String: Any] = [
            "Name": "Test", "Entitlements": [EntitlementReport.increasedMemoryLimitKey: true],
        ]
        let xml = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
        // Real profiles wrap the plist in CMS; surround it with junk bytes.
        let wrapped = Data([0x30, 0x80, 0x06, 0x09]) + xml + Data([0x00, 0xA0, 0x82])
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).mobileprovision")
        try wrapped.write(to: url)
        let entitlements = try #require(CodeSignatureInspector.provisioningProfileEntitlements(at: url))
        #expect(entitlements[EntitlementReport.increasedMemoryLimitKey] as? Bool == true)
    }

    @Test func reportForTestRunnerDoesNotCrash() {
        let report = EntitlementReport.current()
        #expect(report.increasedMemoryLimitInProfile == nil)
    }
}
