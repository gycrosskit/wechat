import Foundation
import OpenKuiklyIOSRender

/// 每 Renderer 一个 receiver，clientProvider 始终返回宿主既有进程 client；回跳仍交给该 client。
@objc(GycWechat)
public final class WechatModule: KRBaseModule {
    public static var clientProvider: (() -> WechatClient?)?
    private let lifecycleLock = NSLock()
    private var invalidated = false
    private var released = false
    private var client: WechatClient?
    private var registration: UUID?
    // Main-only 资源；失效页面的 reservation 保留到 Main 完成取消，避免新页面先认领后被旧清理取消。
    private final class OwnedRequests { var ids = Set<String>() }
    private let ownership = OwnedRequests()
    private var ids: Set<String> { get { ownership.ids } set { ownership.ids = newValue } }
    private var submissions: [String: KuiklyRenderCallback] = [:]
    private var receivedBeforeSubmission = Set<String>()
    private var cancelling = Set<String>()
    private var listener: KuiklyRenderCallback?
    private var active: Bool { withState { !invalidated && !released } }

    // 锁只保护桥的资源归属；SDK/Renderer callback 不在锁内执行，避免跨线程同步通信死锁。
    private func withState<T>(_ body: () -> T) -> T {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }; return body()
    }
    private func nativeClient() -> WechatClient? {
        if let existing = withState({ client }) { return existing }
        let supplied = Self.clientProvider?()
        return withState {
            guard !invalidated, !released else { return nil }
            client = supplied
            return supplied
        }
    }
    public override class func moduleName() -> String { "GycWechat" }
    public override func hrv_call(withMethod method: String, params: Any?, callback: KuiklyRenderCallback?) -> Any? {
        onMain { [weak self] in self?.perform(method, params: params, callback: callback) }
        return nil
    }
    private func perform(_ method: String, params: Any?, callback: KuiklyRenderCallback?) {
        guard active else { return }
        guard let text = params as? String, let data = text.data(using: .utf8),
              let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { deliver(["status": "invalid_content"], callback: callback); return }
        guard let client = nativeClient() else { if active { deliver(["status": "unsupported"], callback: callback) }; return }
        if method == "listen" {
            let restored = (args["restoredRequestId"] as? String).flatMap { client.canResume(requestID: $0) ? $0 : nil }
            let register = withState { () -> Bool in
                guard !invalidated, !released else { return false }
                listener = callback
                if let restored { ids.insert(restored) }
                return registration == nil
            }
            if register {
                let token = client.addModuleListener(owns: { [ownership] in ownership.ids.contains($0) },
                    onSubmitted: { [weak self] in self?.submitted($0, status: $1) },
                    onReceipt: { [weak self] in self?.receipt($0) })
                let retained = withState { () -> Bool in
                    guard !invalidated, !released else { return false }
                    registration = token
                    return true
                }
                if !retained { client.removeModuleListener(token) }
            }
            return
        }
        if method == "unlisten" { release(); return }
        guard withState({ listener != nil }), active else { if active { deliver(["status": "unsupported"], callback: callback) }; return }
        guard let id = args["requestId"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, id.utf16.count <= 128 else { deliver(["status": "invalid_content"], callback: callback); return }
        if method == "cancel" {
            let owned = withState { () -> Bool in
                guard !invalidated, !released, ids.contains(id) else { return false }
                cancelling.insert(id); return true
            }
            guard owned else { if active { deliver(["status": "no_pending"], callback: callback) }; return }
            let cancelled = client.cancelWithResult(requestID: id)
            withState {
                cancelling.remove(id)
                if cancelled { ids.remove(id); submissions.removeValue(forKey: id); receivedBeforeSubmission.remove(id) }
            }
            if active { deliver(["status": cancelled ? "cancelled" : "no_pending"], callback: callback) }
            return
        }
        guard !client.hasModuleOwner(requestID: id) else { deliver(["status": "busy"], callback: callback); return }
        guard ["authorize", "image", "webpage", "transfer"].contains(method) else { deliver(["status": "unsupported"], callback: callback); return }
        let retained = withState { () -> Bool in
            guard !invalidated, !released else { return false }
            ids.insert(id); submissions[id] = callback; return true
        }
        guard retained, active else { return }
        if method == "authorize" { client.authorize(requestID: id); return }
        if method == "transfer" {
            guard let merchant = args["merchantId"] as? String, let app = args["appId"] as? String, let package = args["packageValue"] as? String else { submitted(id, status: "invalid_content"); return }
            client.openMerchantTransfer(requestID: id, merchantID: merchant, appID: app, packageValue: package)
            return
        }
        guard let sceneValue = args["scene"] as? String, ["session", "timeline"].contains(sceneValue),
              let encoded = args[method == "image" ? "data" : "thumbnail"] as? String,
              encoded.utf8.count <= 34_952_536, let bytes = Data(base64Encoded: encoded), !bytes.isEmpty, bytes.count <= 25 * 1024 * 1024 else { submitted(id, status: "invalid_content"); return }
        let scene: WechatScene = sceneValue == "timeline" ? .timeline : .session
        if method == "image" {
            for key in ["recipientId", "senderOpenId"] where args[key] != nil && !(args[key] is String) { submitted(id, status: "invalid_content"); return }
            client.shareImage(requestID: id, data: bytes, scene: scene, recipientID: args["recipientId"] as? String, senderOpenID: args["senderOpenId"] as? String)
        } else {
            guard let url = args["url"] as? String, let title = args["title"] as? String, let description = args["description"] as? String else { submitted(id, status: "invalid_content"); return }
            client.shareWebPage(requestID: id, url: url, title: title, description: description, thumbnail: bytes, scene: scene)
        }
    }
    private func submitted(_ id: String, status: String) {
        let callback: KuiklyRenderCallback? = withState {
            guard !invalidated, !released, ids.contains(id) else { return nil }
            if status == "cancelled" && cancelling.contains(id) { return nil }
            let callback = submissions.removeValue(forKey: id)
            if status != "requested" || receivedBeforeSubmission.remove(id) != nil { ids.remove(id) }
            return callback
        }
        if active { deliver(["status": status], callback: callback) }
    }
    private func receipt(_ value: WechatReceipt) {
        // candidate 只用于投递到原页面，绝不提升成 SDK 证明的 requestId。
        let callback: KuiklyRenderCallback? = withState {
            guard !invalidated, !released, let id = value.requestID ?? value.candidateRequestID, ids.contains(id) else { return nil }
            if submissions[id] != nil { receivedBeforeSubmission.insert(id) } else { ids.remove(id) }
            return listener
        }
        var result: [String: Any] = ["kind": value.kind == .authorization ? "authorization" : value.kind == .share ? "share" : "merchant_transfer",
            "errorCode": value.errorCode, "attribution": value.attribution == .verified ? "VERIFIED" : value.attribution == .singlePending ? "SINGLE_PENDING" : "UNATTRIBUTED"]
        result["requestId"] = value.requestID; result["candidateRequestId"] = value.candidateRequestID
        result["authorizationCode"] = value.authorizationCode; result["pageResult"] = value.pageResult
        if active { deliver(result, callback: callback) }
    }
    private func deliver(_ value: [String: Any], callback: KuiklyRenderCallback?) {
        KuiklyRenderThreadManager.performOnContextQueue { [weak self] in
            guard let self, self.active, self.hr_rootView != nil else { return }
            callback?(value)
        }
    }
    public override func invalidate() {
        let resources = withState { () -> (WechatClient?, UUID?, OwnedRequests?) in
            invalidated = true
            return takeResources()
        }
        // SDK dealloc 会调用此入口；Main 清理只捕获 client/token/ids，不能 retain module。
        let cleanup = { WechatModule.cleanup(resources) }
        if Thread.isMainThread { cleanup() } else { DispatchQueue.main.async(execute: cleanup) }
        super.invalidate()
    }
    /// 调用方持有 lifecycleLock，SDK 清理在释放锁之后执行。
    private func takeResources() -> (WechatClient?, UUID?, OwnedRequests?) {
        guard !released else { return (nil, nil, nil) }
        released = true
        let resources = (client, registration, ownership)
        client = nil; registration = nil; listener = nil
        submissions.removeAll(); receivedBeforeSubmission.removeAll(); cancelling.removeAll()
        return resources
    }
    private static func cleanup(_ resources: (WechatClient?, UUID?, OwnedRequests?)) {
        // 先取消，再解除 reservation；SDK 同步回调中的新 listener 也不能抢占旧 pending。
        for id in resources.2?.ids ?? [] { resources.0?.cancel(requestID: id) }
        resources.2?.ids.removeAll()
        if let token = resources.1 { resources.0?.removeModuleListener(token) }
    }
    private func release() { Self.cleanup(withState { takeResources() }) }
    private func onMain(_ action: @escaping () -> Void) { if Thread.isMainThread { action() } else { DispatchQueue.main.async(execute: action) } }
    public static func register() { precondition(NSClassFromString("GycWechat") == WechatModule.self) }
}
