import Foundation
let s = WechatSession()
var replaced = [String]()
assert(s.begin("auth-one", state: "state-one") == nil)
assert(s.begin("share-one", sharing: .tracked) == nil)
assert(s.begin("transfer-one") == nil)
assert(s.begin("auth-two", state: "state-two", onReplaced: { replaced.append($0) }) == nil)
assert(s.begin("share-two", sharing: .tracked, onReplaced: { replaced.append($0) }) == nil)
assert(s.begin("transfer-two", onReplaced: { replaced.append($0) }) == nil)
assert(replaced == ["auth-one", "share-one", "transfer-one"])
for id in replaced { assert(!s.cancel(id) && !s.submitted(id, accepted: true)) }
assert(s.consumeAuthorization("forged") == nil && s.consumeAuthorization(nil) == nil)
assert(s.consumeAuthorization("state-one") == nil && s.consumeAuthorization("state-two") == "auth-two")
assert(!s.submitted("auth-two", accepted: true))
assert(s.dispatchedShare("share-two") && s.consumeShare() == "share-two")
assert(!s.submitted("share-two", accepted: true))
assert(s.submitted("transfer-two", accepted: true) && !s.isCurrent("transfer-two"))
assert(s.begin("auth-one", state: "reuse") == "invalid_content")
print("Swift three current kinds, replacement, stale cancel/ack/state and early receipt cleanup passed")

final class Store: WechatAuthorizationStore {
    var saved: WechatPendingAuthorization?
    var failSave = false
    var failClear = false
    func load() -> WechatPendingAuthorization? { saved }
    func save(_ request: WechatPendingAuthorization?) throws {
        if request == nil ? failClear : failSave { throw NSError(domain: "storage", code: 1) }
        saved = request
    }
}
let store = Store()
assert(WechatSession(store: store).begin("cold", state: "random-state") == nil)
let restored = WechatSession(store: store)
assert(restored.canResume("cold") && !restored.isSubmitting("cold"))
store.failSave = true
assert(restored.begin("failed-replacement", state: "next-state") == "failed")
assert(store.saved?.requestID == "cold" && restored.isCurrent("cold"))
store.failSave = false; store.failClear = true
assert(restored.consumeAuthorization("random-state") == nil && !restored.cancel("cold"))
assert(store.saved?.requestID == "cold" && restored.isCurrent("cold"))
store.failClear = false
assert(restored.consumeAuthorization("random-state") == "cold" && store.saved == nil)
assert(WechatSession(store: store).consumeAuthorization("random-state") == nil)
assert(restored.begin("cancel", state: "cancel-state") == nil && restored.cancel("cancel"))
assert(WechatSession(store: store).consumeAuthorization("cancel-state") == nil)
final class UnreadableStore: WechatAuthorizationStore {
    func load() throws -> WechatPendingAuthorization? { throw NSError(domain: "storage", code: 1) }
    func save(_ request: WechatPendingAuthorization?) { assertionFailure("must not overwrite unreadable journal") }
}
let unreadable = WechatSession(store: UnreadableStore())
assert(unreadable.begin("blocked", state: "state") == "failed")
assert(unreadable.begin("independent-transfer") == nil)
assert(unreadable.begin("independent-share", sharing: .tracked) == nil)
print("Swift atomic OAuth replacement, trusted restoration, failed clear/cancel retry and kind isolation passed")

let shares = WechatSession()
assert(shares.begin("first", sharing: .tracked) == nil && shares.dispatchedShare("first"))
assert(shares.begin("second", sharing: .tracked) == nil && shares.dispatchedShare("second"))
assert(!shares.canCorrelateShareReceipt && shares.consumeShare() == nil)
assert(shares.submitted("second", accepted: true) && !shares.isCurrent("second"))
let unsent = WechatSession()
assert(unsent.begin("unsent", sharing: .tracked) == nil && unsent.consumeShare() == nil)
assert(unsent.cancel("unsent") && unsent.canCorrelateShareReceipt)
assert(unsent.begin("image-refused", sharing: .submissionOnly) == nil && unsent.dispatchedShare("image-refused"))
assert(unsent.submitted("image-refused", accepted: false) && unsent.canCorrelateShareReceipt)
assert(unsent.begin("image-early", sharing: .submissionOnly) == nil && unsent.dispatchedShare("image-early"))
assert(unsent.consumeShare() == nil && !unsent.canCorrelateShareReceipt)
assert(unsent.submitted("image-early", accepted: false) && !unsent.canCorrelateShareReceipt)
let cancelled = WechatSession()
assert(cancelled.begin("web", sharing: .tracked) == nil && cancelled.dispatchedShare("web"))
assert(cancelled.cancel("web") && !cancelled.canCorrelateShareReceipt)
assert(cancelled.begin("new", sharing: .tracked) == nil && cancelled.dispatchedShare("new"))
assert(cancelled.consumeShare() == nil)
assert(wechatText(String(repeating: "中", count: 256), characters: 256, bytes: 512) == String(repeating: "中", count: 170))
assert(wechatText("a😀", characters: 2, bytes: 512) == "a")
assert(!wechatText(String(repeating: "👨‍👩‍👧‍👦", count: 256), characters: 256, bytes: 512).contains("�"))
print("Swift share candidate downgrade, early image receipt, refusal/cancel and UTF-8 limits passed")

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
