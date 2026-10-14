import Testing

@testable import BerryDriverKit

@Suite("Content hash")
struct ContentHashTests {
    /// Reference values of 64-bit FNV-1a
    /// (http://www.isthe.com/chongo/tech/comp/fnv/index.html#FNV-1a).
    @Test func matchesTheReferenceValues() {
        #expect(ContentHash.fnv1a64("") == "cbf29ce484222325")
        #expect(ContentHash.fnv1a64("a") == "af63dc4c8601ec8c")
        #expect(ContentHash.fnv1a64("foobar") == "85944171f73967e8")
    }
}
