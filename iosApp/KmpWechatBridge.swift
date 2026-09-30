// 本地消费示例；把 WechatCore 改成宿主导出的 KMP framework 名称。
import Foundation
import WechatCore
import GycWechatNative

final class KmpWechatBridge: IosWechatBridge {
    let native: GycWechatNative.WechatClient
    init(appID: String, universalLink: String, listener: WechatListener, store: WechatAuthorizationStore? = nil) {
        native = GycWechatNative.WechatClient(appID: appID, universalLink: universalLink,
            onSubmitted: { id, status in
                listener.onSubmitted(requestId: id, status: Self.status(status))
            }, onReceipt: { response in
                let kind: WechatCore.WechatKind = response.kind == .authorization ? .authorization : response.kind == .share ? .share : .merchantTransfer
                listener.onReceipt(receipt: WechatCore.WechatReceipt(requestId: response.requestID, kind: kind, errorCode: response.errorCode, authorizationCode: response.authorizationCode, pageResult: response.pageResult))
            }, store: store)
    }
    func authorize(requestId: String) { native.authorize(requestID: requestId) }
    func shareImage(requestId: String, data: KotlinByteArray, scene: WechatCore.WechatScene) { native.shareImage(requestID: requestId, data: Self.data(data), scene: scene == .timeline ? .timeline : .session) }
    func shareWebPage(requestId: String, url: String, title: String, description: String, thumbnail: KotlinByteArray, scene: WechatCore.WechatScene) { native.shareWebPage(requestID: requestId, url: url, title: title, description: description, thumbnail: Self.data(thumbnail), scene: scene == .timeline ? .timeline : .session) }
    func openMerchantTransfer(requestId: String, merchantId: String, appId: String, packageValue: String) { native.openMerchantTransfer(requestID: requestId, merchantID: merchantId, appID: appId, packageValue: packageValue) }
    func cancel(requestId: String) { native.cancel(requestID: requestId) }
    private static func data(_ bytes: KotlinByteArray) -> Data {
        Data((0..<bytes.size).map { UInt8(bitPattern: bytes.get(index: $0)) })
    }
    private static func status(_ value: String) -> WechatStatus {
        switch value {
        case "requested": return .requested
        case "busy": return .busy
        case "not_installed": return .notInstalled
        case "unsupported": return .unsupported
        case "invalid_content": return .invalidContent
        case "cancelled": return .cancelled
        default: return .failed
        }
    }
}
