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
    static func isWXAppInstalled() -> Bool { true }
    static func isWXAppSupport() -> Bool { true }
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
        autoAck = true; sent = []; sendCompletions = []; onSend = nil
    }
}
class Store: WechatAuthorizationStore {
    var saved: WechatPendingAuthorization? = .init(requestID: "auth", state: "state")
    var failClear = false
    var onClear: (() -> Void)?
    func load() -> WechatPendingAuthorization? { saved }
    func save(_ request: WechatPendingAuthorization?) throws {
        if request == nil { onClear?(); if failClear { throw NSError(domain: "journal", code: 1) } }
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
WXApi.reset(); WXApi.autoAck = false
var imageStatuses = [(String, String)](), imageReceipts = [WechatReceipt]()
let imageClient = WechatClient(appID: "wxapp", universalLink: "https://example.com/wx",
    onSubmitted: { imageStatuses.append(($0, $1)) }, onReceipt: { imageReceipts.append($0) })
check(imageClient.canCorrelateShareReceipt, "fresh client can provide a singlePending candidate")
for index in 1...3 {
    let id = "image-\(index)"
    imageClient.shareImage(requestID: id, data: Data([1]), scene: .session)
    check(!imageClient.canCorrelateShareReceipt && WXApi.sent.count == index, "in-flight or previously accepted image cannot provide a share candidate")
    imageClient.shareImage(requestID: "overlap-\(index)", data: Data([1]), scene: .session)
    check(imageStatuses.last?.1 == "busy" && WXApi.sent.count == index, "image holds sending exclusion until actual SDK ack")
    WXApi.sendCompletions[index - 1](true); drainSendAck()
    check(imageStatuses.last?.0 == id && imageStatuses.last?.1 == "requested", "requested comes from the real SDK ack")
}
check(imageReceipts.isEmpty, "three images can be sent without any final SDK receipt")
imageClient.authorize(requestID: "after-images-auth")
check(WXApi.sent.last is SendAuthReq, "images without final receipts allow authorization")
let authRequest = WXApi.sent.last as! SendAuthReq
WXApi.sendCompletions.last!(true); drainSendAck()
let authResponse = SendAuthResp(); authResponse.state = authRequest.state
imageClient.onResp(authResponse)
check(imageReceipts.last?.requestID == "after-images-auth" && imageReceipts.last?.attribution == .verified, "image uncertainty does not weaken OAuth state")
imageClient.openMerchantTransfer(requestID: "after-images-transfer", merchantID: "merchant", appID: "app", packageValue: "package")
check(WXApi.sent.last is WXOpenBusinessViewReq, "images allow transfer submission")
WXApi.sendCompletions.last!(true); drainSendAck()
imageClient.onResp(WXOpenBusinessViewResp())
check(imageReceipts.last?.kind == .merchantTransfer && imageReceipts.last?.attribution == .unattributed, "transfer receipt remains unattributed page result")
imageClient.shareWebPage(requestID: "web-after-image", url: "https://example.com", title: "title", description: "", thumbnail: Data([1]), scene: .session)
let webSendIndex = WXApi.sendCompletions.count - 1
imageClient.onResp(SendMessageToWXResp())
check(imageReceipts.last?.candidateRequestID == nil && imageReceipts.last?.attribution == .unattributed, "old image callback cannot become the new webpage candidate")
WXApi.sendCompletions[webSendIndex](true); drainSendAck()
imageClient.shareImage(requestID: "image-after-web", data: Data([1]), scene: .session)
check(imageStatuses.last?.0 == "web-after-image" && imageStatuses.last?.1 == "requested" && WXApi.sent.last is SendMessageToWXReq, "uncertain webpage releases at SDK ack for following image")
check(!imageClient.cancelWithResult(requestID: "web-after-image"), "completed uncertain webpage has no remaining candidate")
WXApi.sendCompletions[webSendIndex](false); drainSendAck()
imageClient.shareImage(requestID: "stale-ack-overlap", data: Data([1]), scene: .session)
check(imageStatuses.last?.1 == "busy", "stale webpage ack/cancel cannot clear newer image")
WXApi.sendCompletions.last!(false); drainSendAck()
check(imageStatuses.last?.0 == "image-after-web" && imageStatuses.last?.1 == "failed", "SDK refusal is never reported as requested")
imageClient.shareImage(requestID: "retry-after-refusal", data: Data([1]), scene: .session)
check(WXApi.sent.count == 8, "SDK refusal releases submission for retry")
print("PASS: three image submissions, actual ack exclusion, early/late unattributed receipts, OAuth/transfer and stale ack/cancel")

WXApi.reset(); WXApi.autoAck = false
var cancellationStatuses = [(String, String)](), cancellationReceipts = [WechatReceipt]()
let cancellationClient = WechatClient(appID: "wxapp", universalLink: "https://example.com/wx",
    onSubmitted: { cancellationStatuses.append(($0, $1)) }, onReceipt: { cancellationReceipts.append($0) })
cancellationClient.shareWebPage(requestID: "cancel-web", url: "https://example.com", title: "title", description: "", thumbnail: Data([1]), scene: .session)
check(cancellationClient.cancelWithResult(requestID: "cancel-web") && !cancellationClient.canCorrelateShareReceipt, "cancelled dispatched webpage permanently loses candidate evidence")
cancellationClient.shareImage(requestID: "after-cancel", data: Data([1]), scene: .session)
check(WXApi.sent.count == 2, "cancelled webpage does not disable ordinary images")
WXApi.sendCompletions[0](true); drainSendAck()
check(!cancellationClient.cancelWithResult(requestID: "cancel-web"), "old webpage cancel cannot clear newer image")
cancellationClient.onResp(SendMessageToWXResp())
check(cancellationReceipts.last?.attribution == .unattributed && cancellationReceipts.last?.candidateRequestID == nil, "cancelled webpage callback has no newer candidate")
cancellationClient.shareImage(requestID: "busy-after-old-callback", data: Data([1]), scene: .session)
check(cancellationStatuses.last?.1 == "busy" && WXApi.sent.count == 2, "cancelled webpage callback cannot release image sending")
WXApi.sendCompletions[1](true); drainSendAck()
cancellationClient.shareWebPage(requestID: "web-after-cancel", url: "https://example.com", title: "title", description: "", thumbnail: Data([1]), scene: .session)
WXApi.sendCompletions[2](true); drainSendAck()
cancellationClient.onResp(SendMessageToWXResp())
check(cancellationReceipts.last?.attribution == .unattributed && !cancellationClient.canCorrelateShareReceipt, "later receipts cannot restore candidate evidence")
cancellationClient.shareImage(requestID: "again-after-cancel", data: Data([1]), scene: .session)
check(WXApi.sent.count == 4, "uncertain webpage does not retain global share occupancy")
print("PASS: cancelled dispatched webpage allows images while late callbacks stay unattributed")

WXApi.reset(); WXApi.autoAck = false
var refusedStatuses = [(String, String)](), refusedReceipts = [WechatReceipt]()
let refusedClient = WechatClient(appID: "wxapp", universalLink: "https://example.com/wx",
    onSubmitted: { refusedStatuses.append(($0, $1)) }, onReceipt: { refusedReceipts.append($0) })
refusedClient.shareImage(requestID: "refused-image", data: Data([1]), scene: .session)
check(!refusedClient.canCorrelateShareReceipt, "in-flight image cannot provide a share candidate")
WXApi.sendCompletions[0](false); drainSendAck()
check(refusedStatuses.last?.1 == "failed" && refusedClient.canCorrelateShareReceipt, "SDK refusal without receipt preserves webpage candidate capability")
refusedClient.shareWebPage(requestID: "web-after-refusal", url: "https://example.com", title: "title", description: "", thumbnail: Data([1]), scene: .session)
WXApi.sendCompletions[1](true); drainSendAck()
refusedClient.onResp(SendMessageToWXResp())
check(refusedReceipts.last?.candidateRequestID == "web-after-refusal" && refusedReceipts.last?.attribution == .singlePending, "refused image does not disable later webpage tasks")
refusedClient.shareImage(requestID: "early-image-refusal", data: Data([1]), scene: .session)
refusedClient.onResp(SendMessageToWXResp())
WXApi.sendCompletions[2](false); drainSendAck()
check(!refusedClient.canCorrelateShareReceipt && refusedReceipts.last?.candidateRequestID == nil, "observed early image receipt keeps attribution uncertain despite later refusal")
refusedClient.shareImage(requestID: "later-refusal", data: Data([1]), scene: .session)
WXApi.sendCompletions[3](false); drainSendAck()
check(!refusedClient.canCorrelateShareReceipt, "later refusal cannot clear existing attribution uncertainty")
print("PASS: image refusal preserves webpage attribution unless an image receipt was already observed")

WXApi.reset(); WXApi.autoAck = false
var earlyStatuses = [(String, String)](), earlyReceipts = [WechatReceipt]()
let earlyClient = WechatClient(appID: "wxapp", universalLink: "https://example.com/wx",
    onSubmitted: { earlyStatuses.append(($0, $1)) }, onReceipt: { earlyReceipts.append($0) })
WXApi.onSend = { _ in earlyClient.onResp(SendMessageToWXResp()) }
earlyClient.shareWebPage(requestID: "early-web", url: "https://example.com", title: "title", description: "", thumbnail: Data([1]), scene: .session)
check(earlyReceipts.last?.candidateRequestID == "early-web" && earlyReceipts.last?.attribution == .singlePending, "fresh webpage retains existing singlePending behavior before send ack")
earlyClient.shareImage(requestID: "early-web-overlap", data: Data([1]), scene: .session)
check(earlyStatuses.last?.1 == "busy", "early tracked receipt does not release SDK send exclusion")
WXApi.sendCompletions[0](true); drainSendAck()
earlyClient.shareImage(requestID: "after-early-web", data: Data([1]), scene: .session)
check(WXApi.sent.count == 2 && earlyReceipts.last?.attribution == .unattributed, "image may follow actual webpage ack and never inherits tracked attribution")
earlyClient.shareImage(requestID: "early-image-overlap", data: Data([1]), scene: .session)
check(earlyStatuses.last?.1 == "busy" && WXApi.sent.count == 2, "early image receipt cannot release current SDK submission")
print("PASS: early webpage receipt keeps singlePending evidence and sending exclusion")

WXApi.reset(); WXApi.autoAck = false
var transferStatuses = [(String, String)]()
let repeatTransferClient = WechatClient(appID: "wxapp", universalLink: "https://example.com/wx",
    onSubmitted: { transferStatuses.append(($0, $1)) })
for index in 1...2 {
    let id = "repeat-transfer-\(index)"
    repeatTransferClient.openMerchantTransfer(requestID: id, merchantID: "merchant", appID: "app", packageValue: "package")
    check(WXApi.sent.count == index && WXApi.sent.last is WXOpenBusinessViewReq, "transfer without final receipt can submit again")
    WXApi.sendCompletions.last!(true); drainSendAck()
    check(transferStatuses.last?.0 == id && transferStatuses.last?.1 == "requested", "transfer releases sending exclusion at SDK ack")
}
print("PASS: Swift repeated transfer without final receipt preserves current non-blocking submission contract")
