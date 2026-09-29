import Foundation

// MARK: - Pack manifest
//
// `manifest.json` sits next to the packs and tells the app what exists, how big it is,
// and how to verify it. The schema version guards against packs newer than the app.

public let packSchemaVersion = 1

public struct PackedState: Codable, Sendable, Equatable {
    public var stateCode: String
    public var fileName: String
    public var compressedBytes: Int64
    public var expandedBytes: Int64
    public var sha256: String
    public var licenseCount: Int
    public var siteCount: Int
    public var frequencyCount: Int

    public init(stateCode: String, fileName: String, compressedBytes: Int64, expandedBytes: Int64,
                sha256: String, licenseCount: Int, siteCount: Int, frequencyCount: Int) {
        self.stateCode = stateCode
        self.fileName = fileName
        self.compressedBytes = compressedBytes
        self.expandedBytes = expandedBytes
        self.sha256 = sha256
        self.licenseCount = licenseCount
        self.siteCount = siteCount
        self.frequencyCount = frequencyCount
    }
}

public struct PackManifest: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var fccSnapshotDate: String
    public var builtAt: String
    public var packs: [PackedState]

    public init(schemaVersion: Int = packSchemaVersion, fccSnapshotDate: String, builtAt: String, packs: [PackedState]) {
        self.schemaVersion = schemaVersion
        self.fccSnapshotDate = fccSnapshotDate
        self.builtAt = builtAt
        self.packs = packs
    }

    public static let fileName = "manifest.json"
}
