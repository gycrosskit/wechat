package io.github.gycrosskit.wechat

enum class WechatScene { SESSION, TIMELINE }
enum class WechatKind { AUTHORIZATION, SHARE, MERCHANT_TRANSFER }
enum class WechatStatus { REQUESTED, BUSY, NOT_INSTALLED, UNSUPPORTED, INVALID_CONTENT, FAILED, CANCELLED }

/** requestId 为空时，平台 SDK 无法证明回执属于哪一次请求。 */
data class WechatReceipt(
    val requestId: String?,
    val kind: WechatKind,
    val errorCode: Int,
    val authorizationCode: String? = null,
    /** 仅为微信确认页 result；success 也不表示资金到账。 */
    val pageResult: String? = null,
)

interface WechatListener {
    fun onSubmitted(requestId: String, status: WechatStatus)
    fun onReceipt(receipt: WechatReceipt)
}

/** 宿主持有进程级实例；主线程调用。requestId 由宿主生成，本实例内不能复用。 */
interface WechatClient {
    fun authorize(requestId: String)
    fun shareImage(requestId: String, data: ByteArray, scene: WechatScene)
    fun shareWebPage(requestId: String, url: String, title: String, description: String, thumbnail: ByteArray, scene: WechatScene)
    fun openMerchantTransfer(requestId: String, merchantId: String, appId: String, packageValue: String)
    /** 只结束本地等待，无法关闭已经打开的微信页面。 */
    fun cancel(requestId: String)
}
