import Foundation
let s = WechatSession()
assert(s.begin("one", state: "secure-state") == nil)
assert(s.begin("two") == "busy")
assert(s.consumeAuthorization("forged") == nil)
assert(s.consumeAuthorization(nil) == nil)
assert(s.submitted("one", accepted: true))
assert(s.consumeAuthorization("secure-state") == "one")
assert(s.consumeAuthorization("secure-state") == nil)
assert(s.begin("one") == "invalid_content")
assert(s.begin("two", state: "next-state") == nil)
assert(!s.cancel("one"))
assert(s.cancel("two"))
assert(s.begin("three", state: "third-state") == nil)
assert(!s.submitted("two", accepted: false))
assert(s.consumeAuthorization("next-state") == nil)
assert(s.consumeAuthorization("third-state") == "three")
print("Swift OAuth state, concurrency, duplicate and late callback checks passed")

final class Store: WechatAuthorizationStore {
    var saved: WechatPendingAuthorization?
    func load() -> WechatPendingAuthorization? { saved }
    func save(_ request: WechatPendingAuthorization?) { saved = request }
}
let store = Store()
assert(WechatSession(store: store).begin("cold", state: "random-state") == nil)
let restored = WechatSession(store: store)
assert(restored.begin("new") == "busy")
assert(restored.consumeAuthorization("forged") == nil)
assert(restored.consumeAuthorization(nil) == nil)
assert(restored.consumeAuthorization("random-state") == "cold")
assert(store.saved == nil)
assert(WechatSession(store: store).consumeAuthorization("random-state") == nil)
assert(restored.begin("cancelled", state: "cancel-state") == nil)
assert(restored.cancel("cancelled"))
assert(WechatSession(store: store).consumeAuthorization("cancel-state") == nil)
print("Swift trusted OAuth journal process recreation and cancellation checks passed")

final class UnreadableStore: WechatAuthorizationStore {
    func load() throws -> WechatPendingAuthorization? { throw NSError(domain: "storage", code: 1) }
    func save(_ request: WechatPendingAuthorization?) { assertionFailure("must not overwrite unreadable journal") }
}
assert(WechatSession(store: UnreadableStore()).begin("blocked", state: "state") == "failed")

final class FailingClearStore: WechatAuthorizationStore {
    var saved: WechatPendingAuthorization?
    var failClear = false
    func load() -> WechatPendingAuthorization? { saved }
    func save(_ request: WechatPendingAuthorization?) throws {
        if request == nil && failClear { throw NSError(domain: "storage", code: 2) }
        saved = request
    }
}
let failingStore = FailingClearStore()
let failedCancel = WechatSession(store: failingStore)
assert(failedCancel.begin("late-after-failed-cancel", state: "late-state") == nil)
assert(failedCancel.submitted("late-after-failed-cancel", accepted: true))
failingStore.failClear = true
assert(!failedCancel.cancel("unknown"))
assert(!failedCancel.cancel("late-after-failed-cancel"))
assert(failingStore.saved?.requestID == "late-after-failed-cancel")
assert(failedCancel.begin("new", state: "new-state") == "busy")
failingStore.failClear = false
assert(failedCancel.consumeAuthorization("late-state") == "late-after-failed-cancel")
assert(!failedCancel.cancel("late-after-failed-cancel"))
assert(failedCancel.begin("cancel-retry", state: "retry-state") == nil)
failingStore.failClear = true
assert(!failedCancel.cancel("cancel-retry"))
failingStore.failClear = false
assert(failedCancel.cancel("cancel-retry"))
assert(failingStore.saved == nil)
assert(failedCancel.consumeAuthorization("retry-state") == nil)
print("Swift failed cancel retains trusted pending, late receipt, unknown/completed ID and retry checks passed")

let shares = WechatSession()
assert(shares.begin("share-one", sharing: true) == nil)
assert(shares.begin("share-overlap", sharing: true) == "busy")
shares.dispatchedShare("share-one")
assert(shares.submitted("share-one", accepted: true))
assert(shares.begin("share-overlap", sharing: true) == "busy")
assert(shares.consumeShare() == "share-one")
assert(shares.consumeShare() == nil)
assert(shares.begin("share-two", sharing: true) == nil)
shares.dispatchedShare("share-two")
assert(shares.submitted("share-two", accepted: false))
assert(shares.begin("share-before-send-cancel", sharing: true) == nil)
assert(shares.cancel("share-before-send-cancel"))
assert(shares.begin("share-cancelled", sharing: true) == nil)
shares.dispatchedShare("share-cancelled")
assert(shares.cancel("share-cancelled"))
assert(shares.begin("new-after-cancel", sharing: true) == "unsupported")
assert(shares.consumeShare() == nil)
assert(!shares.submitted("share-cancelled", accepted: true))
let acceptedThenCancelled = WechatSession()
assert(acceptedThenCancelled.begin("accepted-cancel", sharing: true) == nil)
acceptedThenCancelled.dispatchedShare("accepted-cancel")
assert(acceptedThenCancelled.submitted("accepted-cancel", accepted: true))
assert(acceptedThenCancelled.cancel("accepted-cancel"))
assert(acceptedThenCancelled.consumeShare() == nil)
assert(acceptedThenCancelled.begin("accepted-new", sharing: true) == "unsupported")
assert(shares.begin("auth-after-cancel", state: "state") == nil)
assert(shares.consumeAuthorization("state") == "auth-after-cancel")
let early = WechatSession()
assert(early.begin("early", sharing: true) == nil)
early.dispatchedShare("early")
assert(early.consumeShare() == "early")
assert(early.submitted("early", accepted: true))
assert(early.begin("next", sharing: true) == nil)
assert(wechatText(String(repeating: "中", count: 256), characters: 256, bytes: 512) == String(repeating: "中", count: 170))
assert(wechatText(String(repeating: "文", count: 512), characters: 512, bytes: 1024).utf8.count == 1023)
assert(wechatText(String(repeating: "a", count: 300), characters: 256, bytes: 512).count == 256)
assert(!wechatText(String(repeating: "👨‍👩‍👧‍👦", count: 256), characters: 256, bytes: 512).contains("�"))
print("Swift single-pending candidate, BUSY, normal retry, cancellation quarantine, early receipt and UTF-8 policy checks passed")


let neverDispatched = WechatSession()
assert(neverDispatched.begin("not-dispatched", sharing: true) == nil)
assert(neverDispatched.consumeShare() == nil)
assert(neverDispatched.begin("cannot-overtake", state: "state") == "busy")
assert(neverDispatched.cancel("not-dispatched"))
assert(neverDispatched.begin("retry-safe", sharing: true) == nil)
neverDispatched.dispatchedShare("retry-safe")
assert(neverDispatched.consumeShare() == "retry-safe")
let invalidStore = Store()
invalidStore.saved = WechatPendingAuthorization(requestID: "id", state: String(repeating: "s", count: 257))
let invalidRestored = WechatSession(store: invalidStore)
assert(invalidRestored.consumeAuthorization(invalidStore.saved?.state) == nil)
assert(invalidRestored.begin("fresh", state: "fresh-state") == nil)
assert(invalidRestored.consumeAuthorization("fresh-state") == "fresh")
print("Swift pre-dispatch receipt rejection and invalid restoration admission passed")

// String.count 的组合字符不能扩大与 Kotlin/ArkTS 相同的 UTF-16 公共上限。
for id in [String(repeating: "😀", count: 65), String(repeating: "e\u{0301}", count: 65)] {
    assert(WechatSession().begin(id, state: "state") == "invalid_content")
}
assert(WechatSession().begin(String(repeating: "😀", count: 64), state: String(repeating: "😀", count: 128)) == nil)
for (id, state) in [(String(repeating: "😀", count: 65), "state"), ("id", String(repeating: "😀", count: 129))] {
    let store = Store(); store.saved = WechatPendingAuthorization(requestID: id, state: state)
    let restored = WechatSession(store: store)
    assert(restored.consumeAuthorization(state) == nil)
    assert(restored.begin("fresh", state: "fresh-state") == nil)
}
print("Swift request ID and trusted journal use UTF16 128/256 limits")

let boundaryStore = Store()
boundaryStore.saved = WechatPendingAuthorization(requestID: String(repeating: "😀", count: 64), state: String(repeating: "😀", count: 128))
assert(WechatSession(store: boundaryStore).consumeAuthorization(boundaryStore.saved?.state) == String(repeating: "😀", count: 64))
