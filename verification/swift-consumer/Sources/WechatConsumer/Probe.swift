import Foundation
import GycWechatNative
public func probe(client: WechatClient) -> (String) -> Void {
    // 编译独立模块的公开 API，不触发微信请求。
    return { id in client.cancel(requestID: id) }
}

public func imageProbe(client: WechatClient) -> () -> Void {
    // 仅编译新增参数，不执行返回的闭包。
    return { client.shareImage(requestID: "image", data: Data([1]), scene: .session, recipientID: "trusted-recipient", senderOpenID: "trusted-sender") }
}

public func receiptProbe(receipt: WechatReceipt) -> (String?, WechatAttribution) {
    (receipt.candidateRequestID, receipt.attribution)
}

public final class AuthorizationStoreProbe: WechatAuthorizationStore {
    private var request: WechatPendingAuthorization?
    public func load() -> WechatPendingAuthorization? { request }
    public func save(_ request: WechatPendingAuthorization?) { self.request = request }
}
