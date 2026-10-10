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
    static func registerApp(_ id: String, universalLink: String) -> Bool { true }
    static func isWXAppInstalled() -> Bool { true }
    static func isWXAppSupport() -> Bool { true }
    static func send(_ req: BaseReq, completion: (Bool) -> Void) { completion(true) }
    static func handleOpen(_ url: URL, delegate: WXApiDelegate) -> Bool {
        calls += 1; pending.append(WeakDelegate(delegate)); dispatch?(delegate); return accepted
    }
    static func handleOpenUniversalLink(_ activity: NSUserActivity, delegate: WXApiDelegate) -> Bool {
        handleOpen(activity.webpageURL!, delegate: delegate)
    }
    static func reset() { calls = 0; pending = []; dispatch = nil; accepted = true }
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
    shareClient.shareImage(requestID: "first", data: Data([1]), scene: .session)
    // 实际 send 的 Main ack 为异步，运行 RunLoop 消化后再发起第二笔请求。
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    WXApi.dispatch = { $0.onResp(SendMessageToWXResp()) }
    check(handle(shareClient), "\(name): first share callback")
    shareClient.shareImage(requestID: "second", data: Data([1]), scene: .session)
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
