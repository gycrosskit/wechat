import io.github.gycrosskit.wechat.*
fun probe(client: WechatClient, listener: WechatListener) {
    val result = WechatReceipt("id", WechatKind.AUTHORIZATION, 0, "code")
    listener.onReceipt(result)
    val methods: List<() -> Unit> = listOf(
        { client.authorize("authorization") },
        { client.shareImage("image", byteArrayOf(1), WechatScene.TIMELINE) },
        { client.shareImage("recipient-image", byteArrayOf(1), WechatScene.SESSION, "trusted-recipient", "trusted-sender") },
        { client.shareWebPage("webpage", "https://example.com", "title", "description", byteArrayOf(1), WechatScene.SESSION) },
        { client.openMerchantTransfer("transfer", "merchant", "app", "server-package") },
        { client.cancel("authorization") },
    )
    // 仅编译公共 API，不执行 methods、不发起微信操作。
}

class RequestStoreProbe : WechatRequestStore {
    private var request: WechatPendingRequest? = null
    override fun load() = request
    override fun save(request: WechatPendingRequest?) { this.request = request }
}
