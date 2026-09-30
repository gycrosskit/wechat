import Foundation
import GycWechatNative
public func probe(client: WechatClient) -> (String) -> Void {
    // 编译独立模块的公开 API，不触发微信请求。
    return { id in client.cancel(requestID: id) }
}
