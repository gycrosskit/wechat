import UIKit
import Foundation
import OpenKuiklyIOSRender
let native = WechatClient()
WechatModule.clientProvider = { native }
WechatModule.register(); precondition(WechatModule.moduleName() == "GycWechat")
let old = WechatModule(), next = WechatModule()
var oldReceipts = [[String: Any]](), nextReceipts = [[String: Any]](), submissions = [String](), acks = [String]()
_ = old.hrv_call(withMethod: "listen", params: "{}", callback: { oldReceipts.append($0 as! [String: Any]) })
_ = next.hrv_call(withMethod: "listen", params: "{\"restoredRequestId\":\"untrusted\"}", callback: { nextReceipts.append($0 as! [String: Any]) })
_ = old.hrv_call(withMethod: "authorize", params: "{\"requestId\":\"one\"}", callback: { submissions.append(($0 as! [String: Any])["status"] as! String) })
precondition(submissions.isEmpty && native.starts == ["one"])
_ = next.hrv_call(withMethod: "authorize", params: "{\"requestId\":\"one\"}", callback: { acks.append(($0 as! [String: Any])["status"] as! String) })
precondition(acks == ["busy"] && submissions.isEmpty)
// SDK receipt may precede send completion. Keep both callbacks and the original owner.
native.emit(WechatReceipt(requestID: nil, candidateRequestID: "one", kind: .share, errorCode: 0, attribution: .singlePending))
precondition(oldReceipts.count == 1 && nextReceipts.isEmpty)
precondition(oldReceipts[0]["requestId"] == nil && oldReceipts[0]["candidateRequestId"] as? String == "one" && oldReceipts[0]["attribution"] as? String == "SINGLE_PENDING")
native.emitSubmitted("one", "requested")
precondition(submissions == ["requested"])
_ = old.hrv_call(withMethod: "authorize", params: "{\"requestId\":\"two\"}", callback: { submissions.append(($0 as! [String: Any])["status"] as! String) })
native.cancellationSucceeds = false
_ = old.hrv_call(withMethod: "cancel", params: "{\"requestId\":\"two\"}", callback: { acks.append(($0 as! [String: Any])["status"] as! String) })
precondition(submissions == ["requested"] && acks.last == "no_pending")
native.emitSubmitted("two", "requested"); precondition(submissions == ["requested", "requested"])
let semaphore = DispatchSemaphore(value: 0)
DispatchQueue.global().async { old.invalidate(); semaphore.signal() }
semaphore.wait()
native.emit(WechatReceipt(requestID: "two", candidateRequestID: nil, kind: .authorization, errorCode: 0, attribution: .verified))
precondition(oldReceipts.count == 1 && nextReceipts.isEmpty)
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
native.emit(WechatReceipt(requestID: nil, candidateRequestID: nil, kind: .merchantTransfer, errorCode: 0, attribution: .unattributed))
precondition(nextReceipts.isEmpty)
next.invalidate(); precondition(native.observers.isEmpty)
let cancelledCount = native.cancelled.count
old.invalidate(); next.invalidate(); precondition(native.cancelled.count == cancelledCount)
let queued = WechatModule(), queueDone = DispatchSemaphore(value: 0)
DispatchQueue.global().async {
    _ = queued.hrv_call(withMethod: "listen", params: "{}", callback: { _ in preconditionFailure("queued call survived invalidate") })
    queued.invalidate(); queueDone.signal()
}
queueDone.wait(); RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
precondition(native.observers.isEmpty)
let racing = WechatModule()
native.duringRegistration = { racing.invalidate() }
_ = racing.hrv_call(withMethod: "listen", params: "{}", callback: nil)
native.duringRegistration = nil
precondition(native.observers.isEmpty)
native.cancellationSucceeds = true
var dying: WechatModule? = WechatModule()
weak var weakDying = dying
_ = dying?.hrv_call(withMethod: "listen", params: "{}", callback: { _ in })
_ = dying?.hrv_call(withMethod: "authorize", params: "{\"requestId\":\"dying\"}", callback: nil)
let deallocDone = DispatchSemaphore(value: 0)
DispatchQueue.global().async { dying = nil; deallocDone.signal() }
deallocDone.wait(); precondition(weakDying == nil)
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
precondition(native.observers.isEmpty && native.cancelled.filter { $0 == "dying" }.count == 1)
// A destroyed owner remains reserved until its Main cleanup has cancelled the old pending.
let retiring = WechatModule(), replacement = WechatModule()
_ = retiring.hrv_call(withMethod: "listen", params: "{}", callback: { _ in })
_ = retiring.hrv_call(withMethod: "authorize", params: "{\"requestId\":\"restore-race\"}", callback: nil)
native.trusted.insert("restore-race")
let retired = DispatchSemaphore(value: 0)
DispatchQueue.global().async { retiring.invalidate(); retired.signal() }
retired.wait()
assert(native.hasModuleOwner(requestID: "restore-race") && !native.canResume(requestID: "restore-race"))
_ = replacement.hrv_call(withMethod: "listen", params: "{\"restoredRequestId\":\"restore-race\"}", callback: { _ in preconditionFailure("new owner claimed before old cleanup") })
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
precondition(!native.hasModuleOwner(requestID: "restore-race") && native.cancelled.filter { $0 == "restore-race" }.count == 1)
replacement.invalidate()
// ContextQueue invalidation boundary.
let contextModule = WechatModule()
var contextReplies = 0
_ = contextModule.hrv_call(withMethod: "listen", params: "{}", callback: { _ in contextReplies += 1 })
KuiklyRenderThreadManager.paused = true
_ = contextModule.hrv_call(withMethod: "authorize", params: "{\"requestId\":\"context\"}", callback: { _ in contextReplies += 1 })
native.emitSubmitted("context", "requested")
contextModule.invalidate()
KuiklyRenderThreadManager.paused = false; KuiklyRenderThreadManager.drain()
precondition(contextReplies == 0 && native.observers.isEmpty)
// End ContextQueue boundary.
print("Production Wechat Swift receiver: submit/receipt evidence, cancellation, repeated invalidate, queued/registration races and dealloc cleanup passed (SDK/render boundaries stubbed)")

// Submission-only images release Renderer ownership at SDK ack, including a nil callback.
func shareArguments(_ id: String) -> String {
    let args = ["requestId": id, "data": "AQ==", "thumbnail": "AQ==", "scene": "session",
        "url": "https://example.com", "title": "title", "description": ""]
    return String(data: try! JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
}
let shareModule = WechatModule()
var shareReceipts = [[String: Any]](), shareStatuses = [String]()
_ = shareModule.hrv_call(withMethod: "listen", params: "{}", callback: { shareReceipts.append($0 as! [String: Any]) })
precondition(native.canCorrelateShareReceipt)
_ = shareModule.hrv_call(withMethod: "webpage", params: shareArguments("tracked-web"), callback: nil)
precondition(native.hasModuleOwner(requestID: "tracked-web"))
native.emitSubmitted("tracked-web", "requested")
precondition(native.hasModuleOwner(requestID: "tracked-web"))
native.emit(WechatReceipt(requestID: nil, candidateRequestID: "tracked-web", kind: .share, errorCode: 0, attribution: .singlePending))
precondition(!native.hasModuleOwner(requestID: "tracked-web") && shareReceipts.count == 1)
// Native 已结束旧候选，receiver 下次调用须清除旧 owner；取消旧 ID 不能触及新授权。
_ = shareModule.hrv_call(withMethod: "webpage", params: shareArguments("orphan-web"), callback: nil)
native.emitSubmitted("orphan-web", "requested")
precondition(native.hasModuleOwner(requestID: "orphan-web"))
native.pending.remove("orphan-web")
_ = shareModule.hrv_call(withMethod: "authorize", params: "{\"requestId\":\"auth-with-orphan\"}", callback: nil)
precondition(!native.hasModuleOwner(requestID: "orphan-web"))
var orphanCancel = ""
_ = shareModule.hrv_call(withMethod: "cancel", params: "{\"requestId\":\"orphan-web\"}", callback: { orphanCancel = ($0 as! [String: Any])["status"] as! String })
precondition(orphanCancel == "no_pending" && native.hasPendingRequest(requestID: "auth-with-orphan"))
_ = shareModule.hrv_call(withMethod: "cancel", params: "{\"requestId\":\"auth-with-orphan\"}", callback: nil)
precondition(!native.hasPendingRequest(requestID: "auth-with-orphan"))
for id in ["image-one", "image-two", "image-three"] {
    _ = shareModule.hrv_call(withMethod: "image", params: shareArguments(id), callback: { shareStatuses.append(($0 as! [String: Any])["status"] as! String) })
    precondition(native.hasModuleOwner(requestID: id))
    native.emitSubmitted(id, "requested")
    precondition(!native.hasModuleOwner(requestID: id))
}
precondition(shareStatuses == ["requested", "requested", "requested"] && !native.canCorrelateShareReceipt)
_ = shareModule.hrv_call(withMethod: "image", params: shareArguments("nil-callback-image"), callback: nil)
native.emitSubmitted("nil-callback-image", "requested")
precondition(!native.hasModuleOwner(requestID: "nil-callback-image"))
_ = shareModule.hrv_call(withMethod: "webpage", params: shareArguments("unattributed-web"), callback: { shareStatuses.append(($0 as! [String: Any])["status"] as! String) })
precondition(native.hasModuleOwner(requestID: "unattributed-web"))
native.emit(WechatReceipt(requestID: nil, candidateRequestID: nil, kind: .share, errorCode: 0, attribution: .unattributed))
precondition(native.hasModuleOwner(requestID: "unattributed-web") && shareReceipts.count == 1)
native.emitSubmitted("unattributed-web", "requested")
precondition(!native.hasModuleOwner(requestID: "unattributed-web") && shareStatuses.count == 4)
_ = shareModule.hrv_call(withMethod: "authorize", params: "{\"requestId\":\"auth-after-image\"}", callback: nil)
native.emitSubmitted("auth-after-image", "requested")
precondition(native.hasModuleOwner(requestID: "auth-after-image"))
native.emit(WechatReceipt(requestID: "auth-after-image", candidateRequestID: nil, kind: .authorization, errorCode: 0, attribution: .verified))
precondition(!native.hasModuleOwner(requestID: "auth-after-image") && shareReceipts.count == 2)
_ = shareModule.hrv_call(withMethod: "transfer", params: "{\"requestId\":\"unchanged-transfer\",\"merchantId\":\"merchant\",\"appId\":\"app\",\"packageValue\":\"package\"}", callback: nil)
native.emitSubmitted("unchanged-transfer", "requested")
precondition(native.hasModuleOwner(requestID: "unchanged-transfer"))
let beforeShareCleanup = native.cancelled.count
shareModule.invalidate()
precondition(native.cancelled.count == beforeShareCleanup + 1 && native.cancelled.last == "unchanged-transfer")
precondition(native.observers.isEmpty)
print("Production Swift receiver: image/nil-callback ownership released at ack, unattributed webpage releases, OAuth and transfer ownership preserved")

// A successful OAuth callback may arrive before the app is active and before send completion.
do {
    let client = WechatClient()
    WechatModule.clientProvider = { client }
    let module = WechatModule()
    var received = [[String: Any]]()
    _ = module.hrv_call(withMethod: "listen", params: "{}") { if let value = $0 as? [String: Any] { received.append(value) } }
    _ = module.hrv_call(withMethod: "authorize", params: "{\"requestId\":\"inactive-auth\"}") { _ in }
    UIApplication.shared.applicationState = .inactive
    client.pending.remove("inactive-auth")
    client.emit(WechatReceipt(requestID: "inactive-auth", candidateRequestID: nil, kind: .authorization, errorCode: 0, attribution: .verified))
    client.emitSubmitted("inactive-auth", "requested")
    precondition(received.isEmpty)
    UIApplication.shared.applicationState = .active
    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    precondition(received.count == 1 && received[0]["requestId"] as? String == "inactive-auth")
    module.invalidate()
}
do {
    let client = WechatClient()
    WechatModule.clientProvider = { client }
    let module = WechatModule()
    var received = 0
    _ = module.hrv_call(withMethod: "listen", params: "{}") { _ in received += 1 }
    _ = module.hrv_call(withMethod: "authorize", params: "{\"requestId\":\"cancel-inactive\"}") { _ in }
    UIApplication.shared.applicationState = .inactive
    client.emit(WechatReceipt(requestID: "cancel-inactive", candidateRequestID: nil, kind: .authorization, errorCode: 0, attribution: .verified))
    client.pending.remove("cancel-inactive")
    client.cancellationHasPending = false
    var cancelled = false
    _ = module.hrv_call(withMethod: "cancel", params: "{\"requestId\":\"cancel-inactive\"}") {
        cancelled = ($0 as? [String: Any])?["status"] as? String == "cancelled"
    }
    precondition(cancelled, "已验证但尚未交付的凭据也属于此 Module 的可撤销资源")
    precondition(NotificationCenter.default.observerCount == 0, "取消缓冲凭据必须立即释放活跃态监听，不能等下次回前台")
    UIApplication.shared.applicationState = .active
    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    precondition(received == 0)
    module.invalidate()
}
print("Production receiver defers inactive OAuth until activation; cancellation and early submission retain exact ownership")
