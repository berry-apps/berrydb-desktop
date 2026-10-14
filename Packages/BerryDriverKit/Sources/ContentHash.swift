import Foundation

/// A short hash that tells whether a text changed: the stored schema
/// definitions, and the SQLite driver's fingerprints of a table.
public enum ContentHash {
    /// FNV-1a 64 over the UTF-8 bytes of `text`, as 16 lowercase hex digits
    /// (http://www.isthe.com/chongo/tech/comp/fnv/index.html#FNV-1a). Not
    /// cryptographic: it detects a change and authenticates nothing, and it
    /// keeps the modules that use it free of CryptoKit.
    public static func fnv1a64(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}
