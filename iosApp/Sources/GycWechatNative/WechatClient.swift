import Foundation
import CryptoKit
import ImageIO
import Security
import UIKit
import WechatOpenSDK

/// 微信好友会话或朋友圈。
public enum WechatScene { case session, timeline }
/// 明确 state 证明、单笔候选或无归属证据；候选不能作为证明。
public enum WechatAttribution { case verified, singlePending, unattributed }
/// 授权、分享或商家确认页。
public enum WechatKind { case authorization, share, merchantTransfer }
/// 厂商结果；授权 code 交给后端，确认页结果不表示资金到账。
public struct WechatReceipt {
    /// iOS 分享/转账 SDK 未提供 transaction，因此恒为 nil。
    public let requestID: String?
    /// 实际 SDK 回执类型。
    public let kind: WechatKind
    /// 厂商错误码；成功授权缺少 code 时为 -1。
    public let errorCode: Int32
    /// 敏感短期 OAuth code，其他结果为 nil，禁止日志和持久化。
    public let authorizationCode: String?
    /// 仅表示确认页 result，不能据此判定资金到账。
    public let pageResult: String?
    /// 分享本地单笔候选 ID，默认 nil；SDK 未证明其归属。
    public var candidateRequestID: String? = nil
    /// 默认无归属证据；授权按 state 匹配后为 verified。
    public var attribution: WechatAttribution = .unattributed
}

/// 宿主持有唯一实例；所有入口和回调在主线程。注册前由宿主决定隐私授权。
public final class WechatClient: NSObject, WXApiDelegate {
    private let session: WechatSession
    private let submitted: (String, String) -> Void
    private var receipt: ((WechatReceipt) -> Void)?
    private var receipts: [WechatReceipt] = []
    private var listenerGeneration: UInt64 = 0
    private let registered: Bool
    private var callbackDigests = Set<String>()
    /// Main 注册一次 SDK；宿主传入 appID、HTTPS universalLink 和可选可信 journal。
    public init(appID: String, universalLink: String,
                onSubmitted: @escaping (String, String) -> Void,
                onReceipt: ((WechatReceipt) -> Void)? = nil,
                store: WechatAuthorizationStore? = nil) {
        precondition(Thread.isMainThread)
        self.session = WechatSession(store: store)
        self.submitted = onSubmitted
        self.receipt = onReceipt
        let link = URLComponents(string: universalLink)
        self.registered = !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && link?.scheme == "https" && link?.host != nil && WXApi.registerApp(appID, universalLink: universalLink)
        super.init()
    }
    /// Main 附着回执监听并回放最多 64 笔暂存结果，暂存随后清除。
    public func attach(_ listener: @escaping (WechatReceipt) -> Void) {
        precondition(Thread.isMainThread)
        receipt = listener
        listenerGeneration &+= 1
        let generation = listenerGeneration
        // 回调可同步撤销或替换 owner；未交付项保留给后继注册。
        while listenerGeneration == generation && !receipts.isEmpty {
            listener(receipts.removeFirst())
        }
    }
    /// Main 撤销监听；在途等待保留，回执仍可暂存。
    public func detach() { precondition(Thread.isMainThread); listenerGeneration &+= 1; receipt = nil }
    private func deliver(_ result: WechatReceipt) {
        if let receipt { receipt(result) } else {
            // ponytail: 最多缓存 64 笔，跨进程结果交付由宿主保存。
            if receipts.count == 64 { receipts.removeFirst() }
            receipts.append(result)
        }
    }
    /// Main 将 URL 交官方 SDK 验证；摘要去重但不保存包含 code 的原始 URL。
    public func handleOpenURL(_ url: URL) -> Bool {
        precondition(Thread.isMainThread)
        guard registered, !alreadyHandled(url.absoluteString) else { return false }
        return WXApi.handleOpen(url, delegate: self)
    }
    /// Main 将 Universal Link 交官方 SDK 验证并摘要去重。
    public func handleUniversalLink(_ activity: NSUserActivity) -> Bool {
        precondition(Thread.isMainThread)
        guard registered, let url = activity.webpageURL, !alreadyHandled(url.absoluteString) else { return false }
        return WXApi.handleOpenUniversalLink(activity, delegate: self)
    }
    /// Main 开始 OAuth；生成安全随机 state 并严格匹配最终回执。
    public func authorize(requestID: String) {
        precondition(Thread.isMainThread)
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { submitted(requestID, "failed"); return }
        let state = random.map { String(format: "%02x", $0) }.joined()
        guard begin(requestID, state: state) else { return }
        let request = SendAuthReq()
        request.scope = "snsapi_userinfo"
        request.state = state
        send(request, id: requestID)
    }
    /// Main 分享编码图片，最大 25 MiB；指定联系人使用同 App 的可信双方 openId，不降级普通好友。
    public func shareImage(requestID: String, data: Data, scene: WechatScene, recipientID: String? = nil, senderOpenID: String? = nil) {
        precondition(Thread.isMainThread)
        guard begin(requestID, sharing: true) else { return }
        if let recipientID {
            guard !recipientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, scene == .session else { reject(requestID, "invalid_content"); return }
            guard senderOpenID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { reject(requestID, "unsupported"); return }
        }
        guard !data.isEmpty, data.count <= 25 * 1024 * 1024, let thumb = Self.thumbnail(data) else { reject(requestID, "invalid_content"); return }
        let image = WXImageObject()
        image.imageData = data
        let message = WXMediaMessage()
        message.mediaObject = image
        message.thumbData = thumb
        share(message, id: requestID, scene: scene, recipientID: recipientID, senderOpenID: senderOpenID)
    }
    /// Main 分享无凭据 HTTP(S) 页面；标题/描述限制同时按字符和 UTF-8 字节截断。
    public func shareWebPage(requestID: String, url: String, title: String, description: String, thumbnail: Data, scene: WechatScene) {
        precondition(Thread.isMainThread)
        guard begin(requestID, sharing: true) else { return }
        let address = URLComponents(string: url)
        guard ["http", "https"].contains(address?.scheme?.lowercased() ?? ""), address?.host?.isEmpty == false, address?.user == nil, address?.password == nil,
              url.utf8.count <= 10 * 1024, !thumbnail.isEmpty, thumbnail.count <= 25 * 1024 * 1024, let thumb = Self.thumbnail(thumbnail) else { reject(requestID, "invalid_content"); return }
        let webpage = WXWebpageObject()
        webpage.webpageUrl = url
        let message = WXMediaMessage()
        message.mediaObject = webpage
        message.title = wechatText(title, characters: 256, bytes: 512)
        message.description = wechatText(description, characters: 512, bytes: 1024)
        message.thumbData = thumb
        share(message, id: requestID, scene: scene)
    }
    /// Main 打开商家转账确认页，参数原样 URL 编码；确认回执不表示到账。
    public func openMerchantTransfer(requestID: String, merchantID: String, appID: String, packageValue: String) {
        precondition(Thread.isMainThread)
        guard begin(requestID) else { return }
        guard [merchantID, appID, packageValue].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              let merchant = Self.encode(merchantID), let app = Self.encode(appID), let package = Self.encode(packageValue) else { reject(requestID, "invalid_content"); return }
        let request = WXOpenBusinessViewReq()
        request.businessType = "requestMerchantTransfer"
        request.query = "mchId=\(merchant)&appId=\(app)&package=\(package)"
        send(request, id: requestID)
    }
    /// Main 清除本地等待，不能关闭微信；已发送分享取消后隔离本实例分享，避免错认迟回执。
    public func cancel(requestID: String) {
        precondition(Thread.isMainThread)
        receipts.removeAll { $0.requestID == requestID || $0.candidateRequestID == requestID }
        if session.cancel(requestID) { submitted(requestID, "cancelled") }
    }
    public func onReq(_ req: BaseReq) {}
    public func onResp(_ resp: BaseResp) {
        precondition(Thread.isMainThread)
        if let auth = resp as? SendAuthResp {
            guard let id = session.consumeAuthorization(auth.state) else { return }
            let code = auth.errCode == 0 ? auth.code.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } : nil
            deliver(WechatReceipt(requestID: id, kind: .authorization, errorCode: auth.errCode == 0 && code == nil ? -1 : auth.errCode, authorizationCode: code, pageResult: nil, attribution: .verified))
        } else if resp is SendMessageToWXResp {
            guard let candidate = session.consumeShare() else { return }
            deliver(WechatReceipt(requestID: nil, kind: .share, errorCode: resp.errCode, authorizationCode: nil, pageResult: nil, candidateRequestID: candidate, attribution: .singlePending))
        } else if let transfer = resp as? WXOpenBusinessViewResp, transfer.businessType == "requestMerchantTransfer" {
            let data = transfer.extMsg?.data(using: .utf8)
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            deliver(WechatReceipt(requestID: nil, kind: .merchantTransfer, errorCode: resp.errCode, authorizationCode: nil, pageResult: json?["result"] as? String))
        }
    }
    private func begin(_ id: String, state: String? = nil, sharing: Bool = false) -> Bool {
        if let status = session.begin(id, state: state, sharing: sharing) { submitted(id, status); return false }
        guard registered else { reject(id, "failed"); return false }
        guard WXApi.isWXAppInstalled() else { reject(id, "not_installed"); return false }
        guard WXApi.isWXAppSupport() else { reject(id, "unsupported"); return false }
        return true
    }
    private func reject(_ id: String, _ status: String) { _ = session.cancel(id); submitted(id, status) }
    private func share(_ message: WXMediaMessage, id: String, scene: WechatScene, recipientID: String? = nil, senderOpenID: String? = nil) {
        let request = SendMessageToWXReq()
        request.bText = false
        request.message = message
        request.scene = scene == .timeline ? Int32(WXSceneTimeline.rawValue) : Int32(WXSceneSession.rawValue)
        if let recipientID {
            request.scene = Int32(WXSceneSpecifiedSession.rawValue)
            request.toUserOpenId = recipientID
            request.openID = senderOpenID ?? ""
        }
        send(request, id: id)
    }
    private func send(_ request: BaseReq, id: String) {
        if request is SendMessageToWXReq { session.dispatchedShare(id) }
        WXApi.send(request) { [weak self] accepted in
            DispatchQueue.main.async {
                guard let self, self.session.submitted(id, accepted: accepted) else { return }
                self.submitted(id, accepted ? "requested" : "failed")
            }
        }
    }
    private func alreadyHandled(_ url: String) -> Bool {
        // 只存摘要，不保留包含 OAuth code 或支付参数的原始 URL。
        let digest = SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
        return !callbackDigests.insert(digest).inserted
    }
    private static func encode(_ value: String) -> String? {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))
    }
    private static func thumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 160] as CFDictionary) else { return nil }
        let bitmap = UIImage(cgImage: image)
        for quality in stride(from: 0.8, through: 0.1, by: -0.1) {
            if let bytes = bitmap.jpegData(compressionQuality: quality), bytes.count <= 32 * 1024 { return bytes }
        }
        return nil
    }
}
