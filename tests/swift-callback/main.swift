import Foundation

protocol WXApiDelegate: AnyObject { func onReq(_ request: BaseReq); func onResp(_ response: BaseResp) }
public class BaseReq { var openID = "" }
class SendAuthReq: BaseReq { var scope = ""; var state = "" }
class SendMessageToWXReq: BaseReq { var bText = false; var scene: Int32 = 0; var message: WXMediaMessage?; var toUserOpenId: String? }
class WXOpenBusinessViewReq: BaseReq { var businessType = ""; var query = "" }
class WXImageObject { var imageData = Data() }
class WXWebpageObject { var webpageUrl = "" }
class WXMediaMessage { var mediaObject: Any?; var thumbData: Data?; var title = ""; var description = "" }
enum Scene: Int32 { case session = 0, timeline = 1, specified = 3 }
let WXSceneSession = Scene.session, WXSceneTimeline = Scene.timeline, WXSceneSpecifiedSession = Scene.specified
public class BaseResp { var errCode: Int32 = 0 }
class SendAuthResp: BaseResp { var state: String? = "state"; var code: String? = "code" }
class SendMessageToWXResp: BaseResp {}
class WXOpenBusinessViewResp: BaseResp { var businessType = "requestMerchantTransfer"; var extMsg: String? = "{\"result\":\"success\"}" }
class WeakDelegate { weak var value: WXApiDelegate?; init(_ value: WXApiDelegate) { self.value = value } }
class WXApi {
    static var calls = 0
    static var pending = [WeakDelegate]()
    static var dispatch: ((WXApiDelegate) -> Void)?
    static var accepted = true
    static var autoAck = true
    static var sent = [BaseReq]()
    static var sendCompletions = [(Bool) -> Void]()
    static var onSend: ((BaseReq) -> Void)?
    static func registerApp(_ id: String, universalLink: String) -> Bool { true }
    static var installed = true
    static var supported = true
    static func isWXAppInstalled() -> Bool { installed }
    static func isWXAppSupport() -> Bool { supported }
    static func send(_ req: BaseReq, completion: @escaping (Bool) -> Void) {
        sent.append(req); sendCompletions.append(completion); onSend?(req)
        if autoAck { completion(true) }
    }
    static func handleOpen(_ url: URL, delegate: WXApiDelegate) -> Bool {
        calls += 1; pending.append(WeakDelegate(delegate)); dispatch?(delegate); return accepted
    }
    static func handleOpenUniversalLink(_ activity: NSUserActivity, delegate: WXApiDelegate) -> Bool {
        handleOpen(activity.webpageURL!, delegate: delegate)
    }
    static func reset() {
        calls = 0; pending = []; dispatch = nil; accepted = true
        autoAck = true; sent = []; sendCompletions = []; onSend = nil; installed = true; supported = true
    }
}
class Store: WechatAuthorizationStore {
    var saved: WechatPendingAuthorization? = .init(requestID: "auth", state: "state")
    var failClear = false
    var failSave = false
    var onClear: (() -> Void)?
    func load() -> WechatPendingAuthorization? { saved }
    func save(_ request: WechatPendingAuthorization?) throws {
        if request == nil { onClear?(); if failClear { throw NSError(domain: "journal", code: 1) } }
        if request != nil && failSave { throw NSError(domain: "journal", code: 2) }
        saved = request
    }
}
func check(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) } }
let url = URL(string: "https://example.com/opaque?code=private")!
let otherURL = URL(string: "https://example.com/other?code=private")!
for universal in [false, true] {
    func handle(_ client: WechatClient, _ value: URL = url) -> Bool {
        if !universal { return client.handleOpenURL(value) }
        let activity = NSUserActivity(activityType: "NSUserActivityTypeBrowsingWeb"); activity.webpageURL = value
        return client.handleUniversalLink(activity)
    }
    let name = universal ? "UniversalLink" : "OpenURL"
    WXApi.reset()
    let store = Store(); var receipts = [WechatReceipt]()
    let client = WechatClient(appID: "wxapp", universalLink: "https://example.com/wx", onSubmitted: { _, _ in }, onReceipt: { receipts.append($0) }, store: store)
    WXApi.dispatch = { $0.onResp(SendAuthResp()) }; store.failClear = true
    check(handle(client), "\(name): SDK accepted first callback")
    check(receipts.isEmpty && store.saved != nil && client.canResume(requestID: "auth"), "\(name): failed clear retains trusted pending")
    store.failClear = false
    check(handle(client), "\(name): same URL must retry after failed journal clear")
    check(WXApi.calls == 2 && receipts.count == 1 && store.saved == nil, "\(name): retry consumes and delivers once")
    check(receipts[0].requestID == "auth" && receipts[0].authorizationCode == "code" && receipts[0].attribution == .verified, "\(name): verified attribution preserved")
    check(!handle(client) && WXApi.calls == 2, "\(name): completed URL deduplicated")
    let sameActivity = NSUserActivity(activityType: "NSUserActivityTypeBrowsingWeb"); sameActivity.webpageURL = url
    check(!client.handleOpenURL(url) && !client.handleUniversalLink(sameActivity), "\(name): both entries share completed digest")

    WXApi.reset(); let asyncStore = Store(); var asyncReceipts = [WechatReceipt]()
    let asyncClient = WechatClient(appID: "wxapp", universalLink: "https://example.com/wx", onSubmitted: { _, _ in }, onReceipt: { asyncReceipts.append($0) }, store: asyncStore)
    check(handle(asyncClient), "\(name): async accepted")
    check(!handle(asyncClient) && WXApi.calls == 1, "\(name): same URL busy before async response")
    check(WXApi.pending[0].value != nil, "\(name): client retains delegate independent of SDK")
    let old = WXApi.pending[0].value!
    let forged = SendAuthResp(); forged.state = "forged"; old.onResp(forged)
    check(asyncReceipts.isEmpty && asyncStore.saved != nil, "\(name): invalid state fails closed")
    check(handle(asyncClient), "\(name): invalid state allows SDK revalidation")
    old.onResp(SendAuthResp())
    check(asyncReceipts.isEmpty && !handle(asyncClient) && WXApi.calls == 2, "\(name): old delegate cannot consume or remove new reservation")
    asyncStore.failClear = true; WXApi.pending[1].value!.onResp(SendAuthResp())
    check(handle(asyncClient) && WXApi.calls == 3, "\(name): asynchronous failed clear allows retry")
    asyncStore.failClear = false
    let active = WXApi.pending[2].value!; active.onResp(SendAuthResp()); active.onResp(SendAuthResp())
    check(asyncReceipts.count == 1 && !handle(asyncClient), "\(name): async retry consumed once")
    check(WXApi.pending[1].value == nil, "\(name): completed delegate released")

    WXApi.reset(); let falseStore = Store(); var falseReceipts = [WechatReceipt]()
    let falseClient = WechatClient(appID: "wxapp", universalLink: "https://example.com/wx", onSubmitted: { _, _ in }, onReceipt: { falseReceipts.append($0) }, store: falseStore)
    var refused: WXApiDelegate?; WXApi.dispatch = { refused = $0 }; WXApi.accepted = false
    check(!handle(falseClient), "\(name): SDK false propagated")
    WXApi.accepted = true; WXApi.dispatch = nil
    check(handle(falseClient), "\(name): SDK false permits retry")
    refused?.onResp(SendAuthResp())
    check(falseReceipts.isEmpty && !handle(falseClient), "\(name): false delegate invalidated before new retry")
    WXApi.pending[1].value!.onResp(SendAuthResp()); check(falseReceipts.count == 1, "\(name): retry after SDK false completes")

    WXApi.reset(); let reentrantStore = Store(); var reentrantClient: WechatClient!; var reentrantReceipts = 0
    reentrantClient = WechatClient(appID: "wxapp", universalLink: "https://example.com/wx", onSubmitted: { _, _ in }, onReceipt: { _ in
        reentrantReceipts += 1; check(!handle(reentrantClient), "\(name): delivery reentry sees committed digest")
    }, store: reentrantStore)
    reentrantStore.onClear = { check(!handle(reentrantClient), "\(name): journal reentry sees in-flight digest") }
    WXApi.dispatch = { $0.onResp(SendAuthResp()) }
    check(handle(reentrantClient) && reentrantReceipts == 1 && WXApi.calls == 1, "\(name): reentry dispatches once")

    WXApi.reset(); let requestStore = Store()
    let requestClient = WechatClient(appID: "wxapp", universalLink: "https://example.com/wx", onSubmitted: { _, _ in }, onReceipt: { _ in check(false, "onReq must not deliver a receipt") }, store: requestStore)
    check(handle(requestClient), "\(name): incoming request accepted")
    WXApi.pending[0].value!.onReq(BaseReq())
    check(WXApi.pending[0].value == nil && !handle(requestClient) && requestStore.saved != nil, "\(name): onReq forwards no-op owner, deduplicates and releases without consuming OAuth")

    WXApi.reset(); let mixedStore = Store(); var mixedReceipts = [WechatReceipt]()
    let mixedClient = WechatClient(appID: "wxapp", universalLink: "https://example.com/wx", onSubmitted: { _, _ in }, onReceipt: { mixedReceipts.append($0) }, store: mixedStore)
    check(handle(mixedClient), "\(name): OAuth dispatch pending")
    let oauthDelegate = WXApi.pending[0].value!
    WXApi.dispatch = { $0.onResp(WXOpenBusinessViewResp()) }
    check(handle(mixedClient, otherURL) && mixedReceipts.count == 1, "\(name): transfer digest independent of OAuth")
    mixedStore.failClear = true; oauthDelegate.onResp(SendAuthResp())
    check(!handle(mixedClient, otherURL) && mixedReceipts.count == 1, "\(name): failed OAuth must not clear unrelated transfer digest")

    WXApi.reset(); var transferReceipts = [WechatReceipt]()
    let transferClient = WechatClient(appID: "wxapp", universalLink: "https://example.com/wx", onSubmitted: { _, _ in }, onReceipt: { transferReceipts.append($0) })
    WXApi.dispatch = { $0.onResp(WXOpenBusinessViewResp()) }
    check(handle(transferClient) && !handle(transferClient), "\(name): transfer duplicate URL suppressed")
    check(transferReceipts.count == 1 && transferReceipts[0].requestID == nil && transferReceipts[0].attribution == .unattributed, "\(name): transfer cannot become authorization or arrival proof")

    WXApi.reset(); var shares = [WechatReceipt]()
    let shareClient = WechatClient(appID: "wxapp", universalLink: "https://example.com/wx", onSubmitted: { _, _ in }, onReceipt: { shares.append($0) })
    shareClient.shareWebPage(requestID: "first", url: "https://example.com", title: "title", description: "", thumbnail: Data([1]), scene: .session)
    // 实际 send 的 Main ack 为异步，运行 RunLoop 消化后再发起第二笔请求。
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    WXApi.dispatch = { $0.onResp(SendMessageToWXResp()) }
    check(handle(shareClient), "\(name): first share callback")
    shareClient.shareWebPage(requestID: "second", url: "https://example.com", title: "title", description: "", thumbnail: Data([1]), scene: .session)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    check(!handle(shareClient) && shares.count == 1, "\(name): old URL cannot consume new share candidate")
    check(handle(shareClient, otherURL) && shares.count == 2 && shares[1].candidateRequestID == "second" && shares[1].requestID == nil && shares[1].attribution == .singlePending, "\(name): share retains singlePending contract")
    print("PASS: \(name) journal retry, async reservation, state, SDK false, old delegate, reentry, share/transfer dedup")
}
WXApi.reset()
weak var releasedClient: WechatClient?
weak var releasedDelegate: WXApiDelegate?
do {
    let transient = WechatClient(appID: "wxapp", universalLink: "https://example.com/wx", onSubmitted: { _, _ in }, store: Store())
    releasedClient = transient; check(transient.handleOpenURL(url), "pending URL accepted")
    releasedDelegate = WXApi.pending[0].value
}
check(releasedClient == nil && releasedDelegate == nil, "delegate closures do not retain client")
print("PASS: client/delegate ownership has no retain cycle")

func drainSendAck() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
func webpage(_ client: WechatClient, _ id: String) {
    client.shareWebPage(requestID: id, url: "https://example.com", title: "title", description: "", thumbnail: Data([1]), scene: .session)
}
WXApi.reset(); WXApi.autoAck = false
var statuses = [(String, String)](), responses = [WechatReceipt]()
let client = WechatClient(appID: "wxapp", universalLink: "https://example.com/wx",
    onSubmitted: { statuses.append(($0, $1)) }, onReceipt: { responses.append($0) })
client.authorize(requestID: "auth-old")
let oldAuth = WXApi.sent.last as! SendAuthReq
webpage(client, "share-old")
client.openMerchantTransfer(requestID: "transfer-old", merchantID: "merchant", appID: "app", packageValue: "package")
check(WXApi.sent.count == 3 && statuses.isEmpty, "three kinds dispatch independently before SDK ack")
client.authorize(requestID: "auth-new")
let auth = WXApi.sent.last as! SendAuthReq
webpage(client, "share-new")
client.openMerchantTransfer(requestID: "transfer-new", merchantID: "merchant", appID: "app", packageValue: "package")
check(WXApi.sent.count == 6 && statuses.map { $0.0 } == ["auth-old", "share-old", "transfer-old"] && statuses.allSatisfy { $0.1 == "cancelled" }, "each new kind cancels its old submission immediately")
for index in 0..<3 { WXApi.sendCompletions[index](true) }; drainSendAck()
check(statuses.count == 3, "late SDK acks do not revive replaced submissions")
for id in ["auth-old", "share-old", "transfer-old"] { check(!client.cancelWithResult(requestID: id), "old cancel does not clear current kind") }
let oldResponse = SendAuthResp(); oldResponse.state = oldAuth.state; client.onResp(oldResponse)
check(responses.isEmpty && client.hasPendingRequest(requestID: "auth-new"), "replaced OAuth state cannot consume the new state")
for index in 3..<6 { WXApi.sendCompletions[index](true) }; drainSendAck()
check(statuses.suffix(3).map { $0.0 } == ["auth-new", "share-new", "transfer-new"] && statuses.suffix(3).allSatisfy { $0.1 == "requested" }, "only current SDK acks finish submissions")
check(client.hasPendingRequest(requestID: "auth-new") && !client.hasPendingRequest(requestID: "transfer-new"), "OAuth retains trusted receipt wait while unattributed transfer releases at ack")
client.onResp(SendMessageToWXResp()); client.onResp(WXOpenBusinessViewResp())
check(responses.count == 2 && responses.allSatisfy { $0.requestID == nil && $0.candidateRequestID == nil && $0.attribution == .unattributed }, "overlapping shares and transfer stay unattributed")
let response = SendAuthResp(); response.state = auth.state; client.onResp(response)
check(responses.last?.requestID == "auth-new" && responses.last?.attribution == .verified, "OAuth state proof remains independent")
client.authorize(requestID: "auth-new")
check(statuses.last?.1 == "invalid_content", "completed IDs cannot be reused")
for index in 0..<66 {
    webpage(client, "retry-\(index)")
    WXApi.sendCompletions.last!(true); drainSendAck()
    check(statuses.last?.0 == "retry-\(index)" && statuses.last?.1 == "requested", "missing final receipt never blocks the next round")
}
print("PASS: per-kind current rounds, immediate cancellation, stale SDK ack/state/cancel isolation and 66 retries")

WXApi.reset(); WXApi.autoAck = false
var reentrant: WechatClient!; var reentrantStatuses = [(String, String)]()
reentrant = WechatClient(appID: "wxapp", universalLink: "https://example.com/wx", onSubmitted: { id, status in
    reentrantStatuses.append((id, status))
    if id == "first", status == "cancelled" { reentrant.authorize(requestID: "third") }
})
reentrant.authorize(requestID: "first")
reentrant.authorize(requestID: "second")
check(WXApi.sent.count == 2 && reentrant.hasPendingRequest(requestID: "third") && !reentrant.hasPendingRequest(requestID: "second"), "replacement callback reentry leaves only third round and prevents second dispatch")
check(reentrantStatuses.map { $0.0 } == ["first", "second"] && reentrantStatuses.allSatisfy { $0.1 == "cancelled" }, "nested replacement completes both superseded waits")
WXApi.sendCompletions[0](false); drainSendAck()
check(reentrantStatuses.count == 2 && reentrant.hasPendingRequest(requestID: "third"), "old rejection cannot clear reentrant successor")
WXApi.sendCompletions[1](true); drainSendAck()
check(reentrantStatuses.last?.0 == "third" && reentrantStatuses.last?.1 == "requested", "successor finishes normally")
print("PASS: cancellation callback reentry commits before callback and suppresses overtaken dispatch")

WXApi.reset(); WXApi.autoAck = false
var earlyStatuses = [(String, String)](), earlyReceipts = [WechatReceipt]()
var early: WechatClient!
early = WechatClient(appID: "wxapp", universalLink: "https://example.com/wx", onSubmitted: { earlyStatuses.append(($0, $1)) }, onReceipt: {
    earlyReceipts.append($0)
    if $0.candidateRequestID == "early-web" { webpage(early, "after-early-web") }
})
WXApi.onSend = { request in if request is SendMessageToWXReq && WXApi.sent.count == 1 { early.onResp(SendMessageToWXResp()) } }
webpage(early, "early-web")
check(WXApi.sent.count == 2 && earlyStatuses.count == 1 && earlyStatuses[0].0 == "early-web" && earlyStatuses[0].1 == "requested", "early final receipt finishes submission and clears round before receipt callback reentry")
check(earlyReceipts[0].candidateRequestID == "early-web" && earlyReceipts[0].requestID == nil && earlyReceipts[0].attribution == .singlePending, "unambiguous fresh share remains candidate only")
WXApi.sendCompletions[0](false); drainSendAck()
check(earlyStatuses.count == 1 && early.hasPendingRequest(requestID: "after-early-web"), "early completed round ignores delayed rejection")
WXApi.sendCompletions[1](true); drainSendAck()
check(earlyStatuses.last?.0 == "after-early-web" && earlyStatuses.last?.1 == "requested", "early receipt permits next submission")
print("PASS: early receipt clears current round, finishes wait once and permits reentrant share")

WXApi.reset(); WXApi.autoAck = false
let imageClient = WechatClient(appID: "wxapp", universalLink: "https://example.com/wx", onSubmitted: { _, _ in })
imageClient.shareImage(requestID: "refused", data: Data([1]), scene: .session)
WXApi.sendCompletions[0](false); drainSendAck()
check(imageClient.canCorrelateShareReceipt, "refused image without receipt preserves candidate capability")
webpage(imageClient, "web-after-refusal")
WXApi.sendCompletions[1](true); drainSendAck()
check(imageClient.cancelWithResult(requestID: "web-after-refusal") && !imageClient.canCorrelateShareReceipt, "cancelled dispatched webpage permanently downgrades candidate evidence")
imageClient.shareImage(requestID: "image", data: Data([1]), scene: .session)
imageClient.onResp(SendMessageToWXResp())
WXApi.sendCompletions[2](false); drainSendAck()
check(!imageClient.canCorrelateShareReceipt, "early image receipt cannot restore evidence after later refusal")
webpage(imageClient, "web-uncertain")
WXApi.sendCompletions[3](true); drainSendAck()
check(!imageClient.hasPendingRequest(requestID: "web-uncertain"), "uncertain shares release after submission without claiming a candidate")
print("PASS: image refusal, accepted/cancelled share uncertainty and submission-only cleanup")

WXApi.reset(); WXApi.autoAck = false
let failingStore = Store(); failingStore.saved = nil
var failedStatuses = [(String, String)]()
let persisted = WechatClient(appID: "wxapp", universalLink: "https://example.com/wx", onSubmitted: { failedStatuses.append(($0, $1)) }, store: failingStore)
persisted.authorize(requestID: "persisted")
let persistedRequest = WXApi.sent[0] as! SendAuthReq
failingStore.failSave = true
persisted.authorize(requestID: "save-failed")
check(failedStatuses.last?.1 == "failed" && persisted.hasPendingRequest(requestID: "persisted") && failingStore.saved?.state == persistedRequest.state, "atomic replacement save failure retains old trusted authorization")
failingStore.failSave = false; failingStore.failClear = true
check(!persisted.cancelWithResult(requestID: "persisted") && persisted.hasPendingRequest(requestID: "persisted"), "failed journal clear preserves active wait")
failingStore.failClear = false
check(persisted.cancelWithResult(requestID: "persisted") && failingStore.saved == nil, "cancel retry clears journal")
WXApi.sendCompletions[0](true); drainSendAck()
check(failedStatuses.last?.1 == "cancelled", "cancelled authorization ignores delayed ack")
print("PASS: OAuth atomic replacement/clear failure and retry")

WXApi.reset(); WXApi.autoAck = false
let routed = WechatClient(appID: "wxapp", universalLink: "https://example.com/wx", onSubmitted: { _, _ in })
var owned = Set(["early-routed"]), routedEvents = [String]()
let route = routed.addModuleListener(owns: { owned.contains($0) }, onSubmitted: { id, status in
    routedEvents.append(status)
    if !routed.hasPendingRequest(requestID: id) { owned.remove(id) }
}, onReceipt: { result in
    routedEvents.append("receipt")
    check(result.requestID == "early-routed", "early receipt stays routed to module owner")
})
routed.authorize(requestID: "early-routed")
let routedResponse = SendAuthResp(); routedResponse.state = (WXApi.sent[0] as! SendAuthReq).state
routed.onResp(routedResponse)
check(routedEvents == ["receipt", "requested"] && owned.isEmpty, "early receipt reaches original module before submission completion releases ownership")
WXApi.sendCompletions[0](true); drainSendAck()
check(routedEvents.count == 2, "early receipt submission completes once")
routed.removeModuleListener(route)
print("PASS: early OAuth receipt module routing precedes ownership release")

WXApi.reset(); WXApi.autoAck = false
var validationStatuses = [(String, String)]()
let validationClient = WechatClient(appID: "wxapp", universalLink: "https://example.com/wx", onSubmitted: { validationStatuses.append(($0, $1)) })
webpage(validationClient, "valid-share")
validationClient.openMerchantTransfer(requestID: "valid-transfer", merchantID: "merchant", appID: "app", packageValue: "package")
validationClient.authorize(requestID: "valid-auth")
validationClient.shareImage(requestID: "empty-image", data: Data(), scene: .session)
validationClient.shareImage(requestID: "oversized-image", data: Data(repeating: 0, count: 25 * 1024 * 1024 + 1), scene: .session)
validationClient.shareImage(requestID: "empty-recipient", data: Data([1]), scene: .session, recipientID: " ", senderOpenID: "sender")
validationClient.shareImage(requestID: "timeline-recipient", data: Data([1]), scene: .timeline, recipientID: "recipient", senderOpenID: "sender")
validationClient.shareImage(requestID: "missing-sender", data: Data([1]), scene: .session, recipientID: "recipient")
validationClient.shareWebPage(requestID: "invalid-url", url: "https://user:password@example.com", title: "", description: "", thumbnail: Data([1]), scene: .session)
validationClient.shareWebPage(requestID: "empty-thumbnail", url: "https://example.com", title: "", description: "", thumbnail: Data(), scene: .session)
for (index, fields) in [[" ", "app", "package"], ["merchant", "", "package"], ["merchant", "app", " "]].enumerated() {
    validationClient.openMerchantTransfer(requestID: "empty-transfer-\(index)", merchantID: fields[0], appID: fields[1], packageValue: fields[2])
}
WXApi.supported = false
webpage(validationClient, "unsupported-share")
WXApi.supported = true; WXApi.installed = false
validationClient.authorize(requestID: "uninstalled-auth")
WXApi.installed = true
check(WXApi.sent.count == 3 && validationStatuses.count == 12 && validationStatuses.allSatisfy { $0.1 != "cancelled" }, "invalid parameters and unavailable SDK do not replace valid current rounds")
for id in ["valid-share", "valid-transfer", "valid-auth"] { check(validationClient.hasPendingRequest(requestID: id), "valid current round survives invalid same-kind attempt") }
webpage(validationClient, "valid-share-successor")
check(WXApi.sent.count == 4 && validationStatuses.last?.0 == "valid-share" && validationStatuses.last?.1 == "cancelled", "valid successor still replaces old share normally")
check(validationClient.hasPendingRequest(requestID: "valid-share-successor") && validationClient.hasPendingRequest(requestID: "valid-transfer") && validationClient.hasPendingRequest(requestID: "valid-auth"), "valid share replacement preserves other kinds")
print("PASS: invalid image/recipient/URL/merchant parameters and unavailable SDK preserve valid current rounds")
