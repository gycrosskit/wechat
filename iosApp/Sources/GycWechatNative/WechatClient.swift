import Foundation
import CryptoKit
import ImageIO
import Security
import UIKit
import WechatOpenSDK

public enum WechatScene { case session, timeline }
public enum WechatAttribution { case verified, singlePending, unattributed }
public enum WechatKind { case authorization, share, merchantTransfer }
public struct WechatReceipt {
    /// iOS 分享/转账 SDK 未提供 transaction，因此恒为 nil。
    public let requestID: String?
    public let kind: WechatKind
    public let errorCode: Int32
    public let authorizationCode: String?
    /// 仅表示确认页 result，不能据此判定资金到账。
    public let pageResult: String?
    public var candidateRequestID: String? = nil
    public var attribution: WechatAttribution = .unattributed
}

/** 宿主持有唯一实例；所有入口和回调在主线程。注册前由宿主决定隐私授权。 */
public final class WechatClient: NSObject, WXApiDelegate {
    private let session: WechatSession
    private let submitted: (String, String) -> Void
    private var receipt: ((WechatReceipt) -> Void)?
    private var receipts: [WechatReceipt] = []
    private let registered: Bool
    private var callbackDigests = Set<String>()
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
    public func attach(_ listener: @escaping (WechatReceipt) -> Void) {
        precondition(Thread.isMainThread)
        receipt = listener
        let buffered = receipts; receipts = []
        buffered.forEach(listener)
    }
    public func detach() { precondition(Thread.isMainThread); receipt = nil }
    private func deliver(_ result: WechatReceipt) {
        if let receipt { receipt(result) } else {
            // ponytail: 最多缓存 64 笔，跨进程结果交付由宿主保存。
            if receipts.count == 64 { receipts.removeFirst() }
            receipts.append(result)
        }
    }
    public func handleOpenURL(_ url: URL) -> Bool {
        precondition(Thread.isMainThread)
        guard registered, !alreadyHandled(url.absoluteString) else { return false }
        return WXApi.handleOpen(url, delegate: self)
    }
    public func handleUniversalLink(_ activity: NSUserActivity) -> Bool {
        precondition(Thread.isMainThread)
        guard registered, let url = activity.webpageURL, !alreadyHandled(url.absoluteString) else { return false }
        return WXApi.handleOpenUniversalLink(activity, delegate: self)
    }
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
    public func shareImage(requestID: String, data: Data, scene: WechatScene, recipientID: String? = nil, senderOpenID: String? = nil) {
        precondition(Thread.isMainThread)
        guard begin(requestID, sharing: true) else { return }
        if let recipientID {
            // 通用 isWXAppSupport 无法证明客户端支持指定联系人，不能静默降级。
            reject(requestID, recipientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || scene != .session ? "invalid_content" : "unsupported"); return
        }
        guard !data.isEmpty, data.count <= 25 * 1024 * 1024, let thumb = Self.thumbnail(data) else { reject(requestID, "invalid_content"); return }
        let image = WXImageObject()
        image.imageData = data
        let message = WXMediaMessage()
        message.mediaObject = image
        message.thumbData = thumb
        share(message, id: requestID, scene: scene)
    }
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
            let code = auth.errCode == 0 ? auth.code : nil
            deliver(WechatReceipt(requestID: id, kind: .authorization, errorCode: auth.errCode == 0 && (code?.isEmpty ?? true) ? -1 : auth.errCode, authorizationCode: code, pageResult: nil, attribution: .verified))
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
    private func share(_ message: WXMediaMessage, id: String, scene: WechatScene) {
        let request = SendMessageToWXReq()
        request.bText = false
        request.message = message
        request.scene = scene == .timeline ? Int32(WXSceneTimeline.rawValue) : Int32(WXSceneSession.rawValue)
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
