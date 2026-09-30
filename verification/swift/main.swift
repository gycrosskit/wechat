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
