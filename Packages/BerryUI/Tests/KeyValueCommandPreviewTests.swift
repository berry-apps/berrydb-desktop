import BerryKeyValueKit
import Testing

@testable import BerryUI

@Suite("KeyValueCommandPreview (docs/architecture/15 §4)")
struct KeyValueCommandPreviewTests {
    @Test func setWithNoTTL() {
        #expect(KeyValueCommandPreview.render(.set(key: "foo", value: "bar", ttl: nil)) == "SET foo bar")
    }

    @Test func setWithTTLAppendsEX() {
        #expect(KeyValueCommandPreview.render(.set(key: "foo", value: "bar", ttl: 120)) == "SET foo bar EX 120")
    }

    @Test func delete() {
        #expect(KeyValueCommandPreview.render(.delete(key: "foo")) == "DEL foo")
    }

    @Test func expire() {
        #expect(KeyValueCommandPreview.render(.expire(key: "foo", ttl: 60)) == "EXPIRE foo 60")
    }

    @Test func hashFieldSet() {
        #expect(KeyValueCommandPreview.render(.hashFieldSet(key: "h", field: "f", value: "v")) == "HSET h f v")
    }

    @Test func hashFieldDelete() {
        #expect(KeyValueCommandPreview.render(.hashFieldDelete(key: "h", field: "f")) == "HDEL h f")
    }

    @Test func listPushToTail() {
        #expect(KeyValueCommandPreview.render(.listPush(key: "l", value: "v", end: .tail)) == "RPUSH l v")
    }

    @Test func listPushToHead() {
        #expect(KeyValueCommandPreview.render(.listPush(key: "l", value: "v", end: .head)) == "LPUSH l v")
    }

    @Test func listRemove() {
        #expect(KeyValueCommandPreview.render(.listRemove(key: "l", value: "v")) == "LREM l 0 v")
    }

    @Test func setAdd() {
        #expect(KeyValueCommandPreview.render(.setAdd(key: "s", member: "m")) == "SADD s m")
    }

    @Test func setRemove() {
        #expect(KeyValueCommandPreview.render(.setRemove(key: "s", member: "m")) == "SREM s m")
    }

    @Test func sortedSetAdd() {
        #expect(KeyValueCommandPreview.render(.sortedSetAdd(key: "z", member: "m", score: 1.5)) == "ZADD z 1.5 m")
    }

    @Test func sortedSetRemove() {
        #expect(KeyValueCommandPreview.render(.sortedSetRemove(key: "z", member: "m")) == "ZREM z m")
    }

    @Test func streamAdd() {
        #expect(KeyValueCommandPreview.render(.streamAdd(key: "st", field: "f", value: "v")) == "XADD st * f v")
    }
}
