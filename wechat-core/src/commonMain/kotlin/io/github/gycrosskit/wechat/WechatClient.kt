package io.github.gycrosskit.wechat

/** 微信好友会话或朋友圈。 */
enum class WechatScene { SESSION, TIMELINE }
/** SDK 明确归属、本地单笔候选或无证据；SINGLE_PENDING 不能当作 VERIFIED。 */
enum class WechatAttribution { VERIFIED, SINGLE_PENDING, UNATTRIBUTED }
/** 微信授权、分享或商家转账确认页；转账回执不表示到账。 */
enum class WechatKind { AUTHORIZATION, SHARE, MERCHANT_TRANSFER }
/** 提交状态；REQUESTED 只表示 SDK 受理，最终结果由回执交付。 */
enum class WechatStatus { REQUESTED, BUSY, NOT_INSTALLED, UNSUPPORTED, INVALID_CONTENT, FAILED, CANCELLED }

/**
 * requestId 为空时，平台 SDK 无法证明回执属于哪一次请求。
 * @property requestId 宿主请求 ID；不能把 candidateRequestId 升格为此字段。
 * @property kind SDK 回执类型。
 * @property errorCode 厂商结果码；授权成功却缺少 code 时组件改为 -1。
 * @property authorizationCode 短期 OAuth code，默认 null；只交宿主后端，禁止日志和持久化。
 * @property pageResult 转账确认页结果，默认 null；不能证明到账。
 * @property candidateRequestId 仅本地单笔等待候选，默认 null。
 * @property attribution 默认有 requestId 时 VERIFIED，否则 UNATTRIBUTED；按平台证据决定。
 */
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

/**
 * 仅允许从同一 App 的可信本地存储恢复；不能从 Intent、Want 或页面参数构造。
 * @property requestId 宿主唯一非空 ID，最多 128 个字符。
 * @property transaction 组件生成的随机关联值，最多 128 个字符。
 * @property kind 恢复后允许消费的回执类型。
 * @property state 授权必须携带非空随机 state，最多 256 个字符；其他类型为 null。
 */
data class WechatPendingRequest(val requestId: String, val transaction: String, val kind: WechatKind, val state: String? = null)

/** 主线程同步、原子读写。save(null) 必须持久清除；失败抛异常，宿主不得重放旧快照。 */
interface WechatRequestStore {
    /** 同步读取唯一可信等待记录；无法读取时抛错，禁止覆盖不可读 journal。 */
    fun load(): WechatPendingRequest?
    /** 原子保存；null 必须持久清除，失败抛错并阻止提交/消费。 */
    fun save(request: WechatPendingRequest?)
}

/** 提交状态与最终回执分开交付；Android/iOS 原生客户端在 Main，Kuikly Module 在页面线程调用。 */
interface WechatListener {
    /** SDK 受理、拒绝或取消的提交状态；REQUESTED 不是授权/分享成功。 */
    fun onSubmitted(requestId: String, status: WechatStatus)
    /** 按 receipt.attribution 处理最终回执；授权 code 是短期敏感字段。 */
    fun onReceipt(receipt: WechatReceipt)
}

/**
 * requestId 由宿主生成，本实例内不能复用；原生客户端由宿主持有进程级实例，Kuikly Module 由页面拥有。
 * Android 入口可从任意线程调用，SDK、store、状态与 listener 回调串行到 Main；iOS 遵守原生 Main 约束。
 * Kuikly Module 的入口及回调由宿主保持在页面线程，不自动切换到原生 Main。
 * Unit 返回不保证已发送，必须等 onSubmitted(REQUESTED) 确认 SDK 真实受理，再等 onReceipt 处理最终回执。
 */
interface WechatClient {
    /** 请求 OAuth code；组件生成随机 state 并严格匹配回跳，宿主后端负责换票。 */
    fun authorize(requestId: String)
    /** recipientId 为同 App 可信目标 openId；senderOpenId 为当前发送者的可信 openId。非空目标不降级普通好友。 */
    fun shareImage(requestId: String, data: ByteArray, scene: WechatScene, recipientId: String? = null, senderOpenId: String? = null)
    /** 分享无凭据 HTTP(S) 页面；缩略图是编码图片，标题/描述按厂商字符与 UTF-8 字节限制截断。 */
    fun shareWebPage(requestId: String, url: String, title: String, description: String, thumbnail: ByteArray, scene: WechatScene)
    /** 打开厂商确认页；三个参数来自宿主可信后端，packageValue 原样编码且不写日志。 */
    fun openMerchantTransfer(requestId: String, merchantId: String, appId: String, packageValue: String)
    /**
     * 只结束本地等待，无法关闭已经打开的微信页面。CANCELLED 仅在本地等待清除或尚未执行的入队请求终止成功后通知。
     * Android 后台调用会排队；存储清除失败或未知 ID 不通知终态，保留 pending 以便迟回执或取消重试。
     */
    fun cancel(requestId: String)
}

internal const val MAX_WECHAT_IMAGE = 25 * 1024 * 1024

/** 兼容宿主字符策略，并遵守 iOS/OHOS Header 的 UTF-8 字节上限。 */
internal fun wechatText(value: String, characters: Int, bytes: Int): String {
    var text = value.take(characters)
    while (text.encodeToByteArray().size > bytes || text.lastOrNull()?.isHighSurrogate() == true) text = text.dropLast(1)
    return text
}
