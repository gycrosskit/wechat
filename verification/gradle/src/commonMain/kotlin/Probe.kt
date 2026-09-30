import io.github.gycrosskit.wechat.*
fun probe(client: WechatClient, listener: WechatListener) {
    val result = WechatReceipt("id", WechatKind.AUTHORIZATION, 0, "code")
    listener.onReceipt(result)
    val methods: List<() -> Unit> = listOf(
        { client.authorize("authorization") },
        { client.shareImage("image", byteArrayOf(1), WechatScene.TIMELINE) },
        { client.shareWebPage("webpage", "https://example.com", "title", "description", byteArrayOf(1), WechatScene.SESSION) },
        { client.openMerchantTransfer("transfer", "merchant", "app", "server-package") },
        { client.cancel("authorization") },
    )
    check(methods.size == 5) // 仅编译公共 API，不发起微信操作。
}
