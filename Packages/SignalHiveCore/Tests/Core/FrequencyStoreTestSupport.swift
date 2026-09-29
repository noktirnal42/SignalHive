import GRDB

enum FrequencyStoreTestSupport {
    /// Opens a decompressed pack for writing so a test can tamper with it.
    static func openWritable(_ path: String) throws -> DatabaseQueue {
        try DatabaseQueue(path: path)
    }
}
