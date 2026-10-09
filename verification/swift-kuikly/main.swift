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
