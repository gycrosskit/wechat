package io.github.gycrosskit.wechat.kuikly

import com.tencent.kuikly.core.module.CallbackRef
import com.tencent.kuikly.core.module.Module
import com.tencent.kuikly.core.nvi.serialization.json.JSONObject
import io.github.gycrosskit.wechat.*
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

@OptIn(ExperimentalEncodingApi::class)
/** 页面线程使用；attach 后提交请求，dispose 撤销所有回调并通知原生取消本页等待。 */
class WechatModule : Module(), WechatClient {
    /** 暴露真实平台归属能力，宿主无需再次判断 Android/iOS/OHOS。 */
    val supportsTransferReceiptOwnership: Boolean get() = supportsMerchantTransferReceiptOwnership
    private var listener: WechatListener? = null
    private var listening: CallbackRef? = null
    private val callbacks = mutableMapOf<String, CallbackRef>()
    private val cancellations = mutableMapOf<String, CallbackRef>()
    private class Submission(val kind: WechatKind, val continuation: CancellableContinuation<WechatStatus>)
    private val submissions = mutableMapOf<String, Submission>()
    private var disposed = false
    override fun moduleName(): String = NAME
    /** 注册长期回执；restoredRequestId 只能取宿主可信业务记录，不从页面回跳恢复。 */
    fun attach(listener: WechatListener, restoredRequestId: String? = null) {
        if (disposed) return
        this.listener = listener
        if (listening != null) return
        listening = toNative(true, "listen", JSONObject().apply { restoredRequestId?.let { put("restoredRequestId", it) } }.toString(), { payload ->
            if (disposed || payload == null) return@toNative
            // 替换已受理旧轮是本地控制事件，不伪造微信 SDK 最终回执。
            if (payload.optString("status") == "cancelled") {
                val id = payload.optString("requestId").takeIf(String::isNotBlank) ?: return@toNative
                callbacks.remove(id)?.let(::removeCallback)
                submitted(id, WechatStatus.CANCELLED)
                return@toNative
            }
            val kind = when (payload.optString("kind")) {
                "authorization" -> WechatKind.AUTHORIZATION
                "share" -> WechatKind.SHARE
                "merchant_transfer" -> WechatKind.MERCHANT_TRANSFER
                else -> return@toNative
            }
            val requestId = payload.optString("requestId").takeIf(String::isNotBlank)
            val attribution = when (payload.optString("attribution")) {
                "SINGLE_PENDING" -> WechatAttribution.SINGLE_PENDING
                "UNATTRIBUTED" -> WechatAttribution.UNATTRIBUTED
                "VERIFIED" -> WechatAttribution.VERIFIED
                "" -> if (requestId != null) WechatAttribution.VERIFIED else WechatAttribution.UNATTRIBUTED
                else -> WechatAttribution.UNATTRIBUTED
            }
            val receipt = WechatReceipt(requestId, kind, payload.optInt("errorCode"),
                payload.optString("authorizationCode").takeIf(String::isNotBlank), payload.optString("pageResult").takeIf(String::isNotBlank),
                payload.optString("candidateRequestId").takeIf(String::isNotBlank), attribution)
            val id = receipt.routingRequestId
            // 部分 HAR 的早到回执会消费原生等待，不再发送 submitted；只完成匹配类型的本次提交。
            val waiting = submissions[id]
            if (waiting != null && waiting.kind != receipt.kind) return@toNative
            if (waiting != null && waiting.continuation.isActive) {
                waiting.continuation.resume(WechatStatus.REQUESTED)
                submissions.remove(id)
            }
            this.listener?.onReceipt(receipt)
        }, false).callbackRef
    }
    /** 页面协程等待提交，30 秒到期或取消仅撤销本次 ID；最终回执仍交给 listener。 */
    suspend fun awaitSubmission(requestId: String, kind: WechatKind, send: WechatModule.() -> Unit): WechatStatus {
        if (disposed) return WechatStatus.CANCELLED
        if (listening == null) return WechatStatus.UNSUPPORTED
        if (submissions.containsKey(requestId) || callbacks.containsKey(requestId)) return WechatStatus.BUSY
        var waiting: Submission? = null
        var requested = false
        try {
            return (withTimeoutOrNull(30_000L) {
                suspendCancellableCoroutine { continuation ->
                    if (!continuation.isActive) return@suspendCancellableCoroutine
                    val entry = Submission(kind, continuation)
                    waiting = entry
                    submissions[requestId] = entry
                    try { send() }
                    catch (error: Exception) {
                        if (continuation.isActive) continuation.resumeWith(Result.failure(error))
                    }
                }
            } ?: WechatStatus.FAILED).also {
                // 原生完成到协程恢复之间页面可能已销毁，不能再交付受理结果。
                if (disposed) throw CancellationException("WechatModule is disposed")
                requested = it == WechatStatus.REQUESTED
            }
        } finally {
            if (submissions[requestId] === waiting) submissions.remove(requestId)
            // 早到回执可能没有 submitted；该一次性回调也必须随本次等待释放。
            callbacks.remove(requestId)?.let(::removeCallback)
            if (!requested) cancel(requestId)
        }
    }

    private fun submitted(id: String, status: WechatStatus) {
        submissions.remove(id)?.continuation?.let { if (it.isActive) it.resume(status) }
        listener?.onSubmitted(id, status)
    }

    override fun authorize(requestId: String) = call(requestId, "authorize", JSONObject())
    /**
     * Base64/Data URL 直接跨桥；只规范编码和检查长度，不创建图片 ByteArray 再编码。
     * maximumBytes 允许宿主采用更小的内容上限，不能突破微信 25 MiB 限制。
     */
    fun shareImageBase64(requestId: String, data: String, scene: WechatScene, recipientId: String? = null,
        senderOpenId: String? = null, maximumBytes: Int = MAX_IMAGE) {
        val encoded = normalizeImageBase64(data, maximumBytes)
        if (encoded == null) { submitted(requestId, WechatStatus.INVALID_CONTENT); return }
        call(requestId, "image", JSONObject().apply {
            put("data", encoded); put("scene", sceneValue(scene))
            recipientId?.let { put("recipientId", it) }; senderOpenId?.let { put("senderOpenId", it) }
        })
    }
    override fun shareImage(requestId: String, data: ByteArray, scene: WechatScene, recipientId: String?, senderOpenId: String?) {
        if (data.isEmpty() || data.size > MAX_IMAGE) { submitted(requestId, WechatStatus.INVALID_CONTENT); return }
        call(requestId, "image", JSONObject().apply { put("data", Base64.encode(data)); put("scene", sceneValue(scene)); recipientId?.let { put("recipientId", it) }; senderOpenId?.let { put("senderOpenId", it) } })
    }
    override fun shareWebPage(requestId: String, url: String, title: String, description: String, thumbnail: ByteArray, scene: WechatScene) {
        if (thumbnail.isEmpty() || thumbnail.size > MAX_IMAGE) { submitted(requestId, WechatStatus.INVALID_CONTENT); return }
        call(requestId, "webpage", JSONObject().apply { put("url", url); put("title", title); put("description", description); put("thumbnail", Base64.encode(thumbnail)); put("scene", sceneValue(scene)) })
    }
    override fun openMerchantTransfer(requestId: String, merchantId: String, appId: String, packageValue: String) =
        call(requestId, "transfer", JSONObject().apply { put("merchantId", merchantId); put("appId", appId); put("packageValue", packageValue) })
    override fun cancel(requestId: String) {
        if (disposed || listening == null || cancellations.containsKey(requestId)) return
        var completed = false
        val ref = toNative(false, "cancel", JSONObject().apply { put("requestId", requestId) }.toString(), { payload ->
            completed = true
            cancellations.remove(requestId)
            // 取消失败不是原请求提交失败；原 pending 和迟回执仍由同一 owner 接收。
            if (!disposed && payload?.optString("status") == "cancelled") {
                callbacks.remove(requestId)?.let(::removeCallback)
                submitted(requestId, WechatStatus.CANCELLED)
            }
        }, false).callbackRef
        if (!completed && ref != null) cancellations[requestId] = ref
    }
    private fun call(id: String, method: String, args: JSONObject) {
        if (disposed) { submitted(id, WechatStatus.CANCELLED); return }
        if (listening == null) { submitted(id, WechatStatus.UNSUPPORTED); return }
        if (callbacks.containsKey(id)) { submitted(id, WechatStatus.BUSY); return }
        args.put("requestId", id)
        var completed = false
        val ref = toNative(false, method, args.toString(), { payload ->
            completed = true; callbacks.remove(id)
            val status = when (payload?.optString("status")) {
                "requested" -> WechatStatus.REQUESTED
                "busy" -> WechatStatus.BUSY
                "not_installed" -> WechatStatus.NOT_INSTALLED
                "unsupported" -> WechatStatus.UNSUPPORTED
                "invalid_content" -> WechatStatus.INVALID_CONTENT
                "cancelled" -> WechatStatus.CANCELLED
                "pending" -> null
                else -> WechatStatus.FAILED
            }
            if (!disposed && status != null) submitted(id, status)
        }, false).callbackRef
        if (!completed && ref != null) callbacks[id] = ref
    }
    /** 幂等撤销长期监听、提交/取消确认回调和页面 owner；迟到消息不交付。 */
    fun dispose() {
        if (disposed) return
        disposed = true
        submissions.values.toList().forEach { it.continuation.cancel() }; submissions.clear()
        toNative(false, "unlisten", "{}", null, false)
        listening?.let(::removeCallback); listening = null
        callbacks.values.forEach(::removeCallback); callbacks.clear(); listener = null
        cancellations.values.forEach(::removeCallback); cancellations.clear()
    }
    private fun sceneValue(scene: WechatScene): String = if (scene == WechatScene.TIMELINE) "timeline" else "session"
    companion object {
        /** 原生模块注册名。 */
        const val NAME = "GycWechat"
        private const val MAX_IMAGE = 25 * 1024 * 1024
    }
}

/** 规范 Base64 语法与补位；实际解码仅在原生边界执行，各端接收相同编码。 */
private fun normalizeImageBase64(value: String, maximumBytes: Int): String? {
    if (maximumBytes !in 1..25 * 1024 * 1024 || value.length > 4 * ((maximumBytes + 2) / 3) + 256) return null
    val content = if (value.startsWith("data:")) {
        val comma = value.indexOf(',')
        if (comma !in 1..256 || !value.substring(0, comma).endsWith(";base64")) return null
        value.substring(comma + 1)
    } else value
    val encoded = if (content.any(Char::isWhitespace)) content.filterNot(Char::isWhitespace) else content
    val count = encoded.indexOf('=').let { if (it < 0) encoded.length else it }
    if (count == 0 || count % 4 == 1) return null
    val padding = (4 - count % 4) % 4
    if (encoded.length != count && encoded.length != count + padding) return null
    for (index in encoded.indices) {
        val character = encoded[index]
        if (index >= count) {
            if (character != '=') return null
        } else if (character !in 'A'..'Z' && character !in 'a'..'z' && character !in '0'..'9' && character != '+' && character != '/') return null
    }
    val bytes = count / 4 * 3 + count % 4 * 6 / 8
    if (bytes > maximumBytes) return null
    return if (encoded.length == count && padding != 0) encoded + "=".repeat(padding) else encoded
}
