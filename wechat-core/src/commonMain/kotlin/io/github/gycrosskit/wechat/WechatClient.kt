package io.github.gycrosskit.wechat

enum class WechatScene { SESSION, TIMELINE }
enum class WechatAttribution { VERIFIED, SINGLE_PENDING, UNATTRIBUTED }
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
    /** iOS 单笔等待候选不是 SDK 证明；任务动作由宿主按证据决定。 */
    val candidateRequestId: String? = null,
    val attribution: WechatAttribution = if (requestId != null) WechatAttribution.VERIFIED else WechatAttribution.UNATTRIBUTED,
)

/** 仅允许从同一 App 的可信本地存储恢复；transaction/state 不得从 Intent、Want 或页面参数构造。 */
data class WechatPendingRequest(val requestId: String, val transaction: String, val kind: WechatKind, val state: String? = null)

/** 主线程同步、原子读写。save(null) 必须持久清除；失败抛异常，宿主不得重放旧快照。 */
interface WechatRequestStore {
    fun load(): WechatPendingRequest?
    fun save(request: WechatPendingRequest?)
}

interface WechatListener {
    fun onSubmitted(requestId: String, status: WechatStatus)
    fun onReceipt(receipt: WechatReceipt)
}

/** 宿主持有进程级实例；主线程调用。requestId 由宿主生成，本实例内不能复用。 */
interface WechatClient {
    fun authorize(requestId: String)
    /** recipientId 为同 App 可信目标 openId；senderOpenId 为当前发送者的可信 openId。非空目标不降级普通好友。 */
    fun shareImage(requestId: String, data: ByteArray, scene: WechatScene, recipientId: String? = null, senderOpenId: String? = null)
    fun shareWebPage(requestId: String, url: String, title: String, description: String, thumbnail: ByteArray, scene: WechatScene)
    fun openMerchantTransfer(requestId: String, merchantId: String, appId: String, packageValue: String)
    /** 只结束本地等待，无法关闭已经打开的微信页面。 */
    fun cancel(requestId: String)
}

internal const val MAX_WECHAT_IMAGE = 25 * 1024 * 1024

/** 兼容宿主字符策略，并遵守 iOS/OHOS Header 的 UTF-8 字节上限。 */
internal fun wechatText(value: String, characters: Int, bytes: Int): String {
    var text = value.take(characters)
    while (text.encodeToByteArray().size > bytes || text.lastOrNull()?.isHighSurrogate() == true) text = text.dropLast(1)
    return text
}
